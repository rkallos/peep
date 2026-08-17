import Telemetry.Metrics

# Measures the cost of storing one event's worth of samples three ways:
#
#   per_metric  - one NIF call per metric (what `Peep.Storage` does today)
#   flat        - build a [{id, value, tags}] list, one NIF call per event
#   tagged      - build a [{id, value, tag_idx}] list plus the event's tuple of
#                 distinct tags maps, one NIF call per event, so a tags map
#                 shared across metrics is hashed once
#   build_only  - just the list building, no NIF call, to price the batching tax
#   striped     - one :ets call per metric, for reference
#
# Reported as ns per event, swept over the number of metrics attached to the
# event.

defmodule Loop do
  def run(_fun, 0), do: :ok

  def run(fun, n) do
    fun.()
    run(fun, n - 1)
  end

  def time(fun, n) do
    t0 = :erlang.monotonic_time(:nanosecond)
    run(fun, n)
    t1 = :erlang.monotonic_time(:nanosecond)
    (t1 - t0) / n
  end

  def best_of(fun, n, reps) do
    run(fun, n)

    1..reps
    |> Enum.map(fn _ -> time(fun, n) end)
    |> Enum.min()
  end
end

defmodule Store do
  alias Peep.Storage.Rustler, as: R

  # One NIF call per metric, mirroring `Peep.EventHandler.store_metrics/5`.
  def per_metric([], _resolved), do: :ok

  def per_metric([{id, metric, value, tags} | rest], resolved) do
    R.insert_metric(resolved, id, metric, value, tags)
    per_metric(rest, resolved)
  end

  # Same traversal, but conses a work item instead of calling the NIF, then
  # makes a single batched call at the end.
  def flat(items, resolved) do
    R.insert_metrics_flat(resolved, build_flat(items, []))
  end

  def build_flat([], acc), do: acc

  def build_flat([{id, _metric, value, tags} | rest], acc) do
    build_flat(rest, [{id, value, tags} | acc])
  end

  def tagged(items, tag_results, resolved) do
    R.insert_metrics_tagged(resolved, tag_results, build_tagged(items, []))
  end

  def build_tagged([], acc), do: acc

  def build_tagged([{id, _metric, value, tag_idx} | rest], acc) do
    build_tagged(rest, [{id, value, tag_idx} | acc])
  end

  def striped([], _resolved), do: :ok

  def striped([{id, metric, value, tags} | rest], resolved) do
    Peep.Storage.Striped.insert_metric(resolved, id, metric, value, tags)
    striped(rest, resolved)
  end
end

# A realistic mix: mostly counters/sums with a couple of distributions, and two
# distinct tags maps shared across them (which is why `Peep.Handler.Config`
# deduplicates tag functions in the first place).
metric_specs = [
  {:counter, "count", [:tag_a], 1},
  {:sum, "payload_size", [:tag_a], 512},
  {:counter, "count2", [:tag_a, :tag_b], 1},
  {:last_value, "queue_depth", [:tag_a], 42},
  {:distribution, "duration", [:tag_a], 1500},
  {:distribution, "latency", [:tag_a, :tag_b], 350},
  {:counter, "count3", [:tag_a], 1},
  {:sum, "bytes_out", [:tag_a, :tag_b], 128},
  {:counter, "count4", [:tag_a], 1},
  {:sum, "bytes_in", [:tag_a], 256},
  {:counter, "count5", [:tag_a, :tag_b], 1},
  {:distribution, "wait", [:tag_a], 90}
]

tags_a = %{tag_a: "exchange_1"}
tags_ab = %{tag_a: "exchange_1", tag_b: "channel_2"}

# DISTINCT=1 gives every metric its own tags map, the worst case for the
# `tagged` variant's per-event tag-hash memoization (nothing to share), so the
# two batched shapes can be compared with that advantage removed.
distinct? = System.get_env("DISTINCT") == "1"

n = String.to_integer(System.get_env("N", "500000"))
reps = String.to_integer(System.get_env("REPS", "5"))
counts = System.get_env("COUNTS", "1,2,4,6,12") |> String.split(",") |> Enum.map(&String.to_integer/1)

IO.puts("n = #{n} events per measurement, best of #{reps}, ns per event\n")

header =
  String.pad_trailing("metrics/event", 14) <>
    Enum.map_join(
      ["per_metric", "flat", "tagged", "build_only", "striped"],
      "",
      &String.pad_leading(&1, 12)
    )

IO.puts(header)

for count <- counts do
  specs = Enum.take(metric_specs, count)

  metrics =
    Enum.with_index(specs)
    |> Enum.map(fn {{kind, name, tags, _value}, idx} ->
      event = "bench.event.m#{idx}_#{name}"

      case kind do
        :counter -> counter(event, tags: tags)
        :sum -> sum(event, tags: tags)
        :last_value -> last_value(event, tags: tags)
        :distribution ->
          distribution(event,
            tags: tags,
            reporter_options: [max_value: 1_000_000, bucket_variability: 0.3]
          )
      end
    end)

  {:ok, rs} = Peep.start_link(name: :"bench_rs_#{count}", metrics: metrics, storage: {Peep.Storage.Rustler, []})
  {:ok, st} = Peep.start_link(name: :"bench_st_#{count}", metrics: metrics, storage: :striped)

  {rs_mod, rs_storage} = Peep.Persistent.storage(:"bench_rs_#{count}")
  {st_mod, st_storage} = Peep.Persistent.storage(:"bench_st_#{count}")
  rs_resolved = rs_mod.resolve(rs_storage)
  st_resolved = st_mod.resolve(st_storage)

  itm = Peep.Persistent.ids_to_metrics(Peep.Persistent.fetch(:"bench_rs_#{count}"))

  # {id, metric_struct, value, tags} work items, as the event handler would have
  # them in hand after measurement extraction and tag computation.
  items =
    Enum.with_index(specs)
    |> Enum.map(fn {{_kind, _name, tags, value}, idx} ->
      tags_map =
        cond do
          distinct? and tags == [:tag_a] -> %{tag_a: "exchange_#{idx}"}
          distinct? -> %{tag_a: "exchange_#{idx}", tag_b: "channel_#{idx}"}
          tags == [:tag_a] -> tags_a
          true -> tags_ab
        end

      {idx, elem(itm, idx), value, tags_map}
    end)

  # The event's distinct tags maps, in the order the batch's indices refer to.
  tag_results =
    if distinct? do
      items |> Enum.map(fn {_, _, _, tags} -> tags end) |> List.to_tuple()
    else
      {tags_a, tags_ab}
    end

  # Same items, but carrying the tag_results index instead of the tags map.
  tagged_items =
    items
    |> Enum.with_index()
    |> Enum.map(fn {{id, metric, value, tags}, idx} ->
      tag_idx = if distinct?, do: idx, else: if(tags == tags_a, do: 0, else: 1)
      {id, metric, value, tag_idx}
    end)

  # Prime the first-insert slow paths in every backend.
  Store.per_metric(items, rs_resolved)
  Store.striped(items, st_resolved)

  results = [
    Loop.best_of(fn -> Store.per_metric(items, rs_resolved) end, n, reps),
    Loop.best_of(fn -> Store.flat(items, rs_resolved) end, n, reps),
    Loop.best_of(fn -> Store.tagged(tagged_items, tag_results, rs_resolved) end, n, reps),
    Loop.best_of(fn -> Store.build_flat(items, []) end, n, reps),
    Loop.best_of(fn -> Store.striped(items, st_resolved) end, n, reps)
  ]

  IO.puts(
    String.pad_trailing(to_string(count), 14) <>
      Enum.map_join(results, "", fn ns ->
        String.pad_leading(:erlang.float_to_binary(ns, decimals: 1), 12)
      end)
  )

  GenServer.stop(rs)
  GenServer.stop(st)
end
