import Telemetry.Metrics

# The comparison that justifies (or doesn't) the Rustler branch: aggregate
# `:telemetry.execute/3` throughput under multicore load, striped ETS (what
# `main` uses) against the Rustler backend, per-metric and batched.
#
# Everything goes through a real telemetry handler, so `resolve/1` happens once
# per event inside the handler exactly as in production - never hoisted out of
# the measurement loop, which would pin each worker to one shard and manufacture
# contention that the real handler does not have.

defmodule Loop do
  def run(_fun, 0), do: :ok

  def run(fun, n) do
    fun.()
    run(fun, n - 1)
  end
end

defmodule BatchedHandler do
  @moduledoc false
  # Same prototype handler as scripts/batched_handler_bench.exs.
  # config: {mode, metrics, storage_mod, storage, tag_fns}
  # metrics: [{id, :counter | :other, measurement_key, tag_idx}]

  alias Peep.Storage.Rustler, as: R

  def handle_event(_event, measurements, metadata, {mode, metrics, storage_mod, storage, tag_fns}) do
    resolved = storage_mod.resolve(storage)
    tag_results = compute_tags(tag_fns, metadata, tuple_size(tag_fns) - 1, [])

    case mode do
      :flat -> R.insert_metrics_flat(resolved, build_flat(metrics, measurements, tag_results, []))
      :tagged -> R.insert_metrics_tagged(resolved, tag_results, build_tagged(metrics, measurements, []))
    end
  end

  defp compute_tags(_tag_fns, _metadata, -1, acc), do: List.to_tuple(acc)

  defp compute_tags(tag_fns, metadata, idx, acc) do
    compute_tags(tag_fns, metadata, idx - 1, [elem(tag_fns, idx).(metadata) | acc])
  end

  defp build_flat([], _measurements, _tag_results, acc), do: acc

  defp build_flat([{id, :counter, _meas, tag_idx} | rest], measurements, tag_results, acc) do
    build_flat(rest, measurements, tag_results, [{id, 1, elem(tag_results, tag_idx)} | acc])
  end

  defp build_flat([{id, :other, meas, tag_idx} | rest], measurements, tag_results, acc) do
    case measurements do
      %{^meas => value} when is_number(value) ->
        build_flat(rest, measurements, tag_results, [{id, value, elem(tag_results, tag_idx)} | acc])

      _ ->
        build_flat(rest, measurements, tag_results, acc)
    end
  end

  defp build_tagged([], _measurements, acc), do: acc

  defp build_tagged([{id, :counter, _meas, tag_idx} | rest], measurements, acc) do
    build_tagged(rest, measurements, [{id, 1, tag_idx} | acc])
  end

  defp build_tagged([{id, :other, meas, tag_idx} | rest], measurements, acc) do
    case measurements do
      %{^meas => value} when is_number(value) ->
        build_tagged(rest, measurements, [{id, value, tag_idx} | acc])

      _ ->
        build_tagged(rest, measurements, acc)
    end
  end
end

defmodule Par do
  def throughput(event, measurements, metadata, procs, n) do
    parent = self()

    pids =
      for _ <- 1..procs do
        spawn_link(fn ->
          fun = fn -> :telemetry.execute(event, measurements, metadata) end
          Loop.run(fun, div(n, 10))
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)

          t0 = :erlang.monotonic_time(:nanosecond)
          Loop.run(fun, n)
          t1 = :erlang.monotonic_time(:nanosecond)
          send(parent, {:done, self(), t1 - t0})
        end)
      end

    for pid <- pids, do: receive(do: ({:ready, ^pid} -> :ok))
    for pid <- pids, do: send(pid, :go)
    elapsed = for pid <- pids, do: receive(do: ({:done, ^pid, ns} -> ns))

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

metadata = %{tag_a: "exchange_1", tag_b: "channel_2"}

measurements =
  metric_specs
  |> Enum.with_index()
  |> Map.new(fn {{_kind, name, _tags, value}, idx} -> {:"m#{idx}_#{name}", value} end)

build_metrics = fn event ->
  metric_specs
  |> Enum.with_index()
  |> Enum.map(fn {{kind, name, tags, _value}, idx} ->
    measurement = :"m#{idx}_#{name}"
    opts = [tags: tags, measurement: measurement, event_name: event]

    case kind do
      :counter -> counter("cb.#{measurement}", opts)
      :sum -> sum("cb.#{measurement}", opts)
      :last_value -> last_value("cb.#{measurement}", opts)
      :distribution ->
        distribution(
          "cb.#{measurement}",
          opts ++ [reporter_options: [max_value: 1_000_000, bucket_variability: 0.3]]
        )
    end
  end)
end

striped_event = [:cb, :striped]
ets_event = [:cb, :ets]
rustler_event = [:cb, :rustler]
batch_event = [:cb, :batch]

{:ok, _} =
  Peep.start_link(name: :cb_striped, metrics: build_metrics.(striped_event), storage: :striped)

{:ok, _} = Peep.start_link(name: :cb_ets, metrics: build_metrics.(ets_event), storage: :default)

{:ok, _} =
  Peep.start_link(
    name: :cb_rustler,
    metrics: build_metrics.(rustler_event),
    storage: {Peep.Storage.Rustler, []}
  )

{rs_mod, rs_storage} = Peep.Persistent.storage(:cb_rustler)

{tag_indices, _} =
  Enum.reduce(metric_specs, {%{}, 0}, fn {_kind, _name, tags, _value}, {map, next} ->
    if Map.has_key?(map, tags), do: {map, next}, else: {Map.put(map, tags, next), next + 1}
  end)

tag_fns =
  tag_indices
  |> Enum.sort_by(fn {_tags, idx} -> idx end)
  |> Enum.map(fn {tags, _idx} -> fn md -> Map.take(md, tags) end end)
  |> List.to_tuple()

handler_metrics =
  metric_specs
  |> Enum.with_index()
  |> Enum.map(fn {{kind, name, tags, _value}, idx} ->
    {idx, if(kind == :counter, do: :counter, else: :other), :"m#{idx}_#{name}",
     Map.fetch!(tag_indices, tags)}
  end)

:ok =
  :telemetry.attach(
    {BatchedHandler, :tagged},
    batch_event,
    &BatchedHandler.handle_event/4,
    {:tagged, handler_metrics, rs_mod, rs_storage, tag_fns}
  )

n = String.to_integer(System.get_env("N", "300000"))
schedulers = :erlang.system_info(:schedulers_online)

proc_counts =
  System.get_env("PROCS", "1,#{div(schedulers, 2)},#{schedulers},#{schedulers * 2}")
  |> String.split(",")
  |> Enum.map(&String.to_integer/1)
  |> Enum.uniq()

variants = [
  {"striped (main)", striped_event},
  {"ets", ets_event},
  {"rustler", rustler_event},
  {"rustler batched", batch_event}
]

IO.puts("#{schedulers} schedulers online, 6 metrics/event, #{n} events per worker")
IO.puts("aggregate throughput, million :telemetry.execute/sec\n")

IO.puts(
  String.pad_trailing("workers", 10) <>
    Enum.map_join(variants, "", fn {name, _} -> String.pad_leading(name, 18) end) <>
    String.pad_leading("batched/main", 15)
)

for procs <- proc_counts do
  row =
    for {_name, event} <- variants do
      Par.throughput(event, measurements, metadata, procs, n) / 1_000_000
    end

  [striped, _ets, _rustler, batched] = row

  IO.puts(
    String.pad_trailing(to_string(procs), 10) <>
      Enum.map_join(row, "", &String.pad_leading(:erlang.float_to_binary(&1, decimals: 2), 18)) <>
      String.pad_leading(:erlang.float_to_binary(batched / striped, decimals: 2) <> "x", 15)
  )
end
