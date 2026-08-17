import Telemetry.Metrics

# Prices a whole `:telemetry.execute/3` for one event, so the storage-phase
# numbers from batch_insert_bench.exs can be read against the full per-event
# cost (telemetry dispatch, handler lookup, tag computation, measurement
# extraction - none of which batching touches).

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

event = [:bench, :event]
metadata = %{tag_a: "exchange_1", tag_b: "channel_2"}

n = String.to_integer(System.get_env("N", "500000"))
reps = String.to_integer(System.get_env("REPS", "5"))

counts =
  System.get_env("COUNTS", "1,2,4,6,12") |> String.split(",") |> Enum.map(&String.to_integer/1)

IO.puts("n = #{n} events per measurement, best of #{reps}, ns per :telemetry.execute\n")

IO.puts(
  String.pad_trailing("metrics/event", 14) <>
    Enum.map_join(["no_handler", "rustler", "striped", "ets"], "", &String.pad_leading(&1, 12))
)

for count <- counts do
  specs = Enum.take(metric_specs, count)

  # Every metric shares one event name, so a single :telemetry.execute drives
  # all of them - the case batching is meant to help.
  measurements =
    specs
    |> Enum.with_index()
    |> Map.new(fn {{_kind, name, _tags, value}, idx} -> {:"m#{idx}_#{name}", value} end)

  metrics =
    specs
    |> Enum.with_index()
    |> Enum.map(fn {{kind, name, tags, _value}, idx} ->
      measurement = :"m#{idx}_#{name}"
      opts = [tags: tags, measurement: measurement, event_name: event]

      case kind do
        :counter -> counter("bench.event.#{measurement}", opts)
        :sum -> sum("bench.event.#{measurement}", opts)
        :last_value -> last_value("bench.event.#{measurement}", opts)
        :distribution ->
          distribution(
            "bench.event.#{measurement}",
            opts ++ [reporter_options: [max_value: 1_000_000, bucket_variability: 0.3]]
          )
      end
    end)

  no_handler = Loop.best_of(fn -> :telemetry.execute(event, measurements, metadata) end, n, reps)

  results =
    for {label, storage} <- [
          {:rustler, {Peep.Storage.Rustler, []}},
          {:striped, :striped},
          {:ets, :default}
        ] do
      name = :"bench_#{label}_#{count}"
      {:ok, pid} = Peep.start_link(name: name, metrics: metrics, storage: storage)

      ns = Loop.best_of(fn -> :telemetry.execute(event, measurements, metadata) end, n, reps)

      GenServer.stop(pid)
      ns
    end

  IO.puts(
    String.pad_trailing(to_string(count), 14) <>
      Enum.map_join([no_handler | results], "", fn ns ->
        String.pad_leading(:erlang.float_to_binary(ns, decimals: 1), 12)
      end)
  )
end
