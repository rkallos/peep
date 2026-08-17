import Telemetry.Metrics

# A single-backend `:telemetry.execute/3` workload for profiling under perf.
#
#   BACKEND=striped|ets|rustler|batched  which storage path to exercise
#   PROCS=<n>                            concurrent emitting processes
#   DURATION_MS=<n>                      how long to run
#
# Runs exactly one backend per invocation so every perf sample is attributable
# to that path. Emits one telemetry event per iteration carrying 6 metrics, the
# same mix used by the throughput benchmarks.

defmodule Runner do
  # Checks the clock once per 1000 iterations so the deadline test doesn't show
  # up in the profile.
  def loop(fun, 0, deadline, count) do
    if :erlang.monotonic_time(:millisecond) < deadline do
      loop(fun, 1000, deadline, count)
    else
      count
    end
  end

  def loop(fun, n, deadline, count) do
    fun.()
    loop(fun, n - 1, deadline, count + 1)
  end
end

defmodule BatchedHandler do
  @moduledoc false
  alias Peep.Storage.Rustler, as: R

  def handle_event(_event, measurements, metadata, {metrics, storage_mod, storage, tag_fns}) do
    resolved = storage_mod.resolve(storage)
    tag_results = compute_tags(tag_fns, metadata, tuple_size(tag_fns) - 1, [])
    R.insert_metrics_tagged(resolved, tag_results, build(metrics, measurements, []))
  end

  defp compute_tags(_tag_fns, _metadata, -1, acc), do: List.to_tuple(acc)

  defp compute_tags(tag_fns, metadata, idx, acc) do
    compute_tags(tag_fns, metadata, idx - 1, [elem(tag_fns, idx).(metadata) | acc])
  end

  defp build([], _measurements, acc), do: acc

  defp build([{id, :counter, _meas, tag_idx} | rest], measurements, acc) do
    build(rest, measurements, [{id, 1, tag_idx} | acc])
  end

  defp build([{id, :other, meas, tag_idx} | rest], measurements, acc) do
    case measurements do
      %{^meas => value} when is_number(value) ->
        build(rest, measurements, [{id, value, tag_idx} | acc])

      _ ->
        build(rest, measurements, acc)
    end
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

backend = System.get_env("BACKEND", "striped")
procs = String.to_integer(System.get_env("PROCS", "8"))
duration_ms = String.to_integer(System.get_env("DURATION_MS", "20000"))

event = [:prof, String.to_atom(backend)]
metadata = %{tag_a: "exchange_1", tag_b: "channel_2"}

measurements =
  metric_specs
  |> Enum.with_index()
  |> Map.new(fn {{_kind, name, _tags, value}, idx} -> {:"m#{idx}_#{name}", value} end)

metrics =
  metric_specs
  |> Enum.with_index()
  |> Enum.map(fn {{kind, name, tags, _value}, idx} ->
    measurement = :"m#{idx}_#{name}"
    opts = [tags: tags, measurement: measurement, event_name: event]

    case kind do
      :counter -> counter("prof.#{measurement}", opts)
      :sum -> sum("prof.#{measurement}", opts)
      :last_value -> last_value("prof.#{measurement}", opts)
      :distribution ->
        distribution(
          "prof.#{measurement}",
          opts ++ [reporter_options: [max_value: 1_000_000, bucket_variability: 0.3]]
        )
    end
  end)

storage =
  case backend do
    "striped" -> :striped
    "ets" -> :default
    _ -> {Peep.Storage.Rustler, []}
  end

{:ok, _} = Peep.start_link(name: :prof, metrics: metrics, storage: storage)

if backend == "batched" do
  # Replace Peep's per-metric handler with the batched prototype, so the event
  # drives exactly one NIF call.
  for %{id: id} <- :telemetry.list_handlers(event), do: :telemetry.detach(id)

  {rs_mod, rs_storage} = Peep.Persistent.storage(:prof)

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
      {BatchedHandler, :prof},
      event,
      &BatchedHandler.handle_event/4,
      {handler_metrics, rs_mod, rs_storage, tag_fns}
    )
end

IO.puts(
  "backend=#{backend} procs=#{procs} duration=#{duration_ms}ms pid=#{System.pid()} " <>
    "handlers=#{length(:telemetry.list_handlers(event))}"
)

parent = self()
deadline = :erlang.monotonic_time(:millisecond) + duration_ms

pids =
  for _ <- 1..procs do
    spawn_link(fn ->
      fun = fn -> :telemetry.execute(event, measurements, metadata) end
      count = Runner.loop(fun, 1000, deadline, 0)
      send(parent, {:done, self(), count})
    end)
  end

total = for pid <- pids, reduce: 0 do
  acc -> receive do: ({:done, ^pid, count} -> acc + count)
end

IO.puts(
  "events=#{total} throughput=#{Float.round(total / (duration_ms / 1000) / 1_000_000, 2)}M/sec"
)
