import Telemetry.Metrics

# End-to-end `:telemetry.execute/3` comparison, measured rather than projected:
# Peep's real per-metric handler against a prototype handler that does the same
# work but hands the whole event to the storage backend in one batched NIF call.
#
# Both handlers write into the *same* Rustler storage and see identical
# measurements/metadata; they're attached to two different event names purely so
# neither has to be detached mid-run.

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

defmodule BatchedHandler do
  @moduledoc false
  # Mirrors Peep.EventHandler.handle_event/4 - resolve storage once, compute
  # each distinct tags map once, walk the metric list extracting measurements -
  # but conses a work item per metric instead of calling into storage per
  # metric, then makes a single call at the end.
  #
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

metadata = %{tag_a: "exchange_1", tag_b: "channel_2"}

n = String.to_integer(System.get_env("N", "500000"))
reps = String.to_integer(System.get_env("REPS", "5"))

counts =
  System.get_env("COUNTS", "1,2,4,6,12") |> String.split(",") |> Enum.map(&String.to_integer/1)

IO.puts("n = #{n} events per measurement, best of #{reps}, ns per :telemetry.execute\n")

IO.puts(
  String.pad_trailing("metrics/event", 14) <>
    Enum.map_join(
      ["peep(rustler)", "batch:flat", "batch:tagged", "peep(striped)"],
      "",
      &String.pad_leading(&1, 15)
    )
)

for count <- counts do
  specs = Enum.take(metric_specs, count)
  peep_event = [:bench, :"peep#{count}"]
  batch_event = [:bench, :"batch#{count}"]

  measurements =
    specs
    |> Enum.with_index()
    |> Map.new(fn {{_kind, name, _tags, value}, idx} -> {:"m#{idx}_#{name}", value} end)

  build_metrics = fn event ->
    specs
    |> Enum.with_index()
    |> Enum.map(fn {{kind, name, tags, _value}, idx} ->
      measurement = :"m#{idx}_#{name}"
      opts = [tags: tags, measurement: measurement, event_name: event]

      case kind do
        :counter -> counter("bench.#{measurement}", opts)
        :sum -> sum("bench.#{measurement}", opts)
        :last_value -> last_value("bench.#{measurement}", opts)
        :distribution ->
          distribution(
            "bench.#{measurement}",
            opts ++ [reporter_options: [max_value: 1_000_000, bucket_variability: 0.3]]
          )
      end
    end)
  end

  peep_metrics = build_metrics.(peep_event)

  {:ok, rs_pid} =
    Peep.start_link(
      name: :"bh_rs_#{count}",
      metrics: peep_metrics,
      storage: {Peep.Storage.Rustler, []}
    )

  striped_event = [:bench, :"striped#{count}"]

  {:ok, st_pid} =
    Peep.start_link(
      name: :"bh_st_#{count}",
      metrics: build_metrics.(striped_event),
      storage: :striped
    )

  {rs_mod, rs_storage} = Peep.Persistent.storage(:"bh_rs_#{count}")

  # Dedup tag configurations the same way Peep.Handler.Config does, so the
  # prototype handler evaluates each distinct tags map exactly once per event.
  {tag_indices, _} =
    Enum.reduce(specs, {%{}, 0}, fn {_kind, _name, tags, _value}, {map, next} ->
      if Map.has_key?(map, tags), do: {map, next}, else: {Map.put(map, tags, next), next + 1}
    end)

  tag_fns =
    tag_indices
    |> Enum.sort_by(fn {_tags, idx} -> idx end)
    |> Enum.map(fn {tags, _idx} -> fn md -> Map.take(md, tags) end end)
    |> List.to_tuple()

  handler_metrics =
    specs
    |> Enum.with_index()
    |> Enum.map(fn {{kind, name, tags, _value}, idx} ->
      type = if kind == :counter, do: :counter, else: :other
      {idx, type, :"m#{idx}_#{name}", Map.fetch!(tag_indices, tags)}
    end)

  for mode <- [:flat, :tagged] do
    :ok =
      :telemetry.attach(
        {BatchedHandler, mode, count},
        batch_event,
        &BatchedHandler.handle_event/4,
        {mode, handler_metrics, rs_mod, rs_storage, tag_fns}
      )
  end

  # Every path has its own event name with exactly one handler attached, so no
  # measurement includes another's dispatch.
  peep_rustler =
    Loop.best_of(fn -> :telemetry.execute(peep_event, measurements, metadata) end, n, reps)

  peep_striped =
    Loop.best_of(fn -> :telemetry.execute(striped_event, measurements, metadata) end, n, reps)

  # Both prototype modes share batch_event, so detach one at a time.
  :telemetry.detach({BatchedHandler, :tagged, count})
  batch_flat = Loop.best_of(fn -> :telemetry.execute(batch_event, measurements, metadata) end, n, reps)
  :telemetry.detach({BatchedHandler, :flat, count})

  :ok =
    :telemetry.attach(
      {BatchedHandler, :tagged, count},
      batch_event,
      &BatchedHandler.handle_event/4,
      {:tagged, handler_metrics, rs_mod, rs_storage, tag_fns}
    )

  batch_tagged =
    Loop.best_of(fn -> :telemetry.execute(batch_event, measurements, metadata) end, n, reps)

  :telemetry.detach({BatchedHandler, :tagged, count})

  IO.puts(
    String.pad_trailing(to_string(count), 14) <>
      Enum.map_join([peep_rustler, batch_flat, batch_tagged, peep_striped], "", fn ns ->
        String.pad_leading(:erlang.float_to_binary(ns, decimals: 1), 15)
      end)
  )

  GenServer.stop(rs_pid)
  GenServer.stop(st_pid)
end
