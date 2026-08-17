import Telemetry.Metrics

# Same storage-phase comparison as batch_insert_bench.exs, but run from P
# concurrent processes, to check the batching win survives contention rather
# than being an artifact of a single uncontended writer.

defmodule Loop do
  def run(_fun, 0), do: :ok

  def run(fun, n) do
    fun.()
    run(fun, n - 1)
  end
end

defmodule Store do
  alias Peep.Storage.Rustler, as: R

  def per_metric([], _resolved), do: :ok

  def per_metric([{id, metric, value, tags} | rest], resolved) do
    R.insert_metric(resolved, id, metric, value, tags)
    per_metric(rest, resolved)
  end

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

defmodule Par do
  # Each worker resolves storage itself, on its own scheduler, exactly as
  # `Peep.EventHandler.handle_event/4` does per event.
  def throughput(setup, body, procs, n) do
    parent = self()

    pids =
      for _ <- 1..procs do
        spawn_link(fn ->
          resolved = setup.()
          fun = body.(resolved)
          Loop.run(fun, div(n, 10))
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          end

          t0 = :erlang.monotonic_time(:nanosecond)
          Loop.run(fun, n)
          t1 = :erlang.monotonic_time(:nanosecond)
          send(parent, {:done, self(), t1 - t0})
        end)
      end

    for pid <- pids, do: receive(do: ({:ready, ^pid} -> :ok))
    for pid <- pids, do: send(pid, :go)

    elapsed = for pid <- pids, do: receive(do: ({:done, ^pid, ns} -> ns))

    # Wall clock of the slowest worker; every worker did n events, so this is
    # aggregate events/sec across the whole run.
    procs * n / (Enum.max(elapsed) / 1_000_000_000)
  end
end

metric_specs = [
  {:counter, "count", [:tag_a], 1},
  {:sum, "payload_size", [:tag_a], 512},
  {:counter, "count2", [:tag_a, :tag_b], 1},
  {:last_value, "queue_depth", [:tag_a], 42},
  {:distribution, "duration", [:tag_a], 1500},
  {:distribution, "latency", [:tag_a, :tag_b], 350}
]

tags_a = %{tag_a: "exchange_1"}
tags_ab = %{tag_a: "exchange_1", tag_b: "channel_2"}
tag_results = {tags_a, tags_ab}

metrics =
  metric_specs
  |> Enum.with_index()
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

{:ok, _} = Peep.start_link(name: :par_rs, metrics: metrics, storage: {Peep.Storage.Rustler, []})
{:ok, _} = Peep.start_link(name: :par_st, metrics: metrics, storage: :striped)

{rs_mod, rs_storage} = Peep.Persistent.storage(:par_rs)
{st_mod, st_storage} = Peep.Persistent.storage(:par_st)
itm = Peep.Persistent.ids_to_metrics(Peep.Persistent.fetch(:par_rs))

items =
  metric_specs
  |> Enum.with_index()
  |> Enum.map(fn {{_kind, _name, tags, value}, idx} ->
    {idx, elem(itm, idx), value, if(tags == [:tag_a], do: tags_a, else: tags_ab)}
  end)

tagged_items =
  Enum.map(items, fn {id, metric, value, tags} ->
    {id, metric, value, if(tags == tags_a, do: 0, else: 1)}
  end)

n = String.to_integer(System.get_env("N", "300000"))
schedulers = :erlang.system_info(:schedulers_online)

proc_counts =
  System.get_env("PROCS", "1,#{div(schedulers, 2)},#{schedulers},#{schedulers * 2}")
  |> String.split(",")
  |> Enum.map(&String.to_integer/1)
  |> Enum.uniq()

rs_setup = fn -> rs_mod.resolve(rs_storage) end
st_setup = fn -> st_mod.resolve(st_storage) end

variants = [
  {"per_metric", rs_setup, fn r -> fn -> Store.per_metric(items, r) end end},
  {"flat", rs_setup, fn r -> fn -> Store.flat(items, r) end end},
  {"tagged", rs_setup, fn r -> fn -> Store.tagged(tagged_items, tag_results, r) end end},
  {"striped", st_setup, fn r -> fn -> Store.striped(items, r) end end}
]

IO.puts("#{schedulers} schedulers online, 6 metrics/event, #{n} events per worker")
IO.puts("aggregate million events/sec (higher is better)\n")

IO.puts(
  String.pad_trailing("procs", 8) <>
    Enum.map_join(variants, "", fn {name, _, _} -> String.pad_leading(name, 12) end)
)

for procs <- proc_counts do
  row =
    for {_name, setup, body} <- variants do
      Par.throughput(setup, body, procs, n) / 1_000_000
    end

  IO.puts(
    String.pad_trailing(to_string(procs), 8) <>
      Enum.map_join(row, "", &String.pad_leading(:erlang.float_to_binary(&1, decimals: 2), 12))
  )
end
