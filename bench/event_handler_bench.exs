import Telemetry.Metrics

metrics = [
  counter("bench.event.count", tags: [:tag_a]),
  counter("bench.event.count2", tags: [:tag_a, :tag_b]),
  sum("bench.event.payload_size", tags: [:tag_a]),
  last_value("bench.event.queue_depth", tags: [:tag_a]),
  distribution("bench.event.duration",
    tags: [:tag_a],
    reporter_options: [max_value: 1_000_000, bucket_variability: 0.3]
  ),
  distribution("bench.event.latency",
    tags: [:tag_a, :tag_b],
    reporter_options: [max_value: 65536, bucket_variability: 0.3]
  )
]

{:ok, _pid} = Peep.start_link(name: :bench, metrics: metrics, storage: :striped)

measurements = %{
  count: 1,
  payload_size: 512,
  queue_depth: 42,
  duration: 1500,
  latency: 350
}

metadata = %{tag_a: "exchange_1", tag_b: "channel_2"}
event = [:bench, :event]

parallel = String.to_integer(System.get_env("BENCH_PARALLEL", "1"))
IO.puts("Running with parallel: #{parallel}")

Benchee.run(
  %{
    "telemetry_execute" => fn ->
      :telemetry.execute(event, measurements, metadata)
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  parallel: parallel
)

GenServer.stop(:bench)
