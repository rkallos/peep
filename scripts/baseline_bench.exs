import Telemetry.Metrics

# Branch-agnostic `:telemetry.execute/3` throughput benchmark, so the same
# script can measure main, perf/dist-lookup before and after its changes, and
# the rebased Rustler branch in one session on one machine. Comparing runs
# across machines or sessions is what made the earlier attribution muddy.
#
# Only exercises storage backends that exist in the checkout: Peep.Storage.ETS
# and .Striped always, Peep.Storage.Rustler when the module is present.
#
#   METRICS=<n>  metrics attached to the single event (default 6)
#   PROCS=a,b,c  worker counts (default 1, half, all, double the schedulers)
#   N=<n>        events per worker per measurement

defmodule Loop do
  def run(_fun, 0), do: :ok

  def run(fun, n) do
    fun.()
    run(fun, n - 1)
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

# A mix weighted the way a real event usually is: mostly counters and sums with
# a couple of distributions, over two distinct tags maps.
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

n = String.to_integer(System.get_env("N", "300000"))
n_metrics = String.to_integer(System.get_env("METRICS", "6"))
specs = Enum.take(metric_specs, n_metrics)
metadata = %{tag_a: "exchange_1", tag_b: "channel_2"}

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
      :counter -> counter("bl.#{measurement}", opts)
      :sum -> sum("bl.#{measurement}", opts)
      :last_value -> last_value("bl.#{measurement}", opts)
      :distribution ->
        distribution(
          "bl.#{measurement}",
          opts ++ [reporter_options: [max_value: 1_000_000, bucket_variability: 0.3]]
        )
    end
  end)
end

backends =
  [{"striped", :striped}, {"ets", :default}] ++
    if Code.ensure_loaded?(Peep.Storage.Rustler) do
      [{"rustler", {Peep.Storage.Rustler, []}}]
    else
      []
    end

# Each backend gets its own event name so no measurement includes another's
# handler dispatch.
started =
  for {label, storage} <- backends do
    event = [:bl, String.to_atom(label)]
    name = :"bl_#{label}"
    {:ok, _} = Peep.start_link(name: name, metrics: build_metrics.(event), storage: storage)
    {label, event}
  end

schedulers = :erlang.system_info(:schedulers_online)

proc_counts =
  System.get_env("PROCS", "1,#{div(schedulers, 2)},#{schedulers},#{schedulers * 2}")
  |> String.split(",")
  |> Enum.map(&String.to_integer/1)
  |> Enum.uniq()

IO.puts("#{:erlang.system_info(:system_architecture)}")
IO.puts("#{schedulers} schedulers online, #{n_metrics} metrics/event, #{n} events per worker")
IO.puts("aggregate throughput, million :telemetry.execute/sec\n")

IO.puts(
  String.pad_trailing("workers", 10) <>
    Enum.map_join(started, "", fn {label, _} -> String.pad_leading(label, 14) end)
)

for procs <- proc_counts do
  row =
    for {_label, event} <- started do
      Par.throughput(event, measurements, metadata, procs, n) / 1_000_000
    end

  IO.puts(
    String.pad_trailing(to_string(procs), 10) <>
      Enum.map_join(row, "", &String.pad_leading(:erlang.float_to_binary(&1, decimals: 2), 14))
  )
end
