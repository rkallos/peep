import Telemetry.Metrics

# Does the per-shard RwLock (and the atomic RMW) cost anything once every
# scheduler is writing? Compares today's locked+atomic batched insert against
# the lock-free, non-atomic one at increasing concurrency.
#
# The lock-free variant is genuinely racy - two processes can land on the same
# shard (see the migration hazard). Tags are pre-primed so no map ever grows
# during the measurement, which keeps the race to lost counts rather than
# corrupting hashbrown. It is a measurement, not a candidate implementation.

defmodule Loop do
  def run(_fun, 0), do: :ok

  def run(fun, n) do
    fun.()
    run(fun, n - 1)
  end
end

defmodule Par do
  # `pin?` binds worker i to scheduler i via spawn_opt's :scheduler option, so
  # no worker can migrate and no two workers can ever resolve the same shard.
  # That isolates inherent lock/atomic cost from cost caused by shard
  # collisions.
  def throughput(body, procs, n, pin?) do
    parent = self()

    pids =
      for i <- 1..procs do
        opts = if pin?, do: [:link, {:scheduler, rem(i - 1, :erlang.system_info(:schedulers)) + 1}], else: [:link]

        :erlang.spawn_opt(fn ->
          fun = body.()
          Loop.run(fun, div(n, 10))
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)

          t0 = :erlang.monotonic_time(:nanosecond)
          Loop.run(fun, n)
          t1 = :erlang.monotonic_time(:nanosecond)
          send(parent, {:done, self(), t1 - t0})
        end, opts)
      end

    for pid <- pids, do: receive(do: ({:ready, ^pid} -> :ok))
    for pid <- pids, do: send(pid, :go)
    elapsed = for pid <- pids, do: receive(do: ({:done, ^pid, ns} -> ns))

    procs * n / (Enum.max(elapsed) / 1_000_000_000)
  end
end

alias Peep.Storage.Rustler, as: R

metrics = for i <- 1..6, do: counter("lockpar.c#{i}", tags: [:tag_a])

{:ok, _} = Peep.start_link(name: :lockpar, metrics: metrics, storage: {Peep.Storage.Rustler, []})
{R, storage} = Peep.Persistent.storage(:lockpar)

tags = %{tag_a: "exchange_1"}
batch = for id <- 0..5, do: {id, 1, tags}

# Prime every shard for both variants, so nothing grows a map mid-measurement.
schedulers = :erlang.system_info(:schedulers_online)

for _ <- 1..(schedulers * 50) do
  Task.async(fn ->
    resolved = R.resolve(storage)
    R.insert_metrics_flat(resolved, batch)
    R.insert_counters_unlocked_plain(resolved, batch)
  end)
  |> Task.await()
end

n = String.to_integer(System.get_env("N", "300000"))

proc_counts =
  System.get_env("PROCS", "1,#{div(schedulers, 2)},#{schedulers},#{schedulers * 2}")
  |> String.split(",")
  |> Enum.map(&String.to_integer/1)
  |> Enum.uniq()

# `resolve/1` runs *inside* the timed body, once per event, exactly as
# `Peep.EventHandler.handle_event/4` does. Hoisting it out of the loop pins each
# worker to whichever shard it was spawned on, which manufactures collisions
# that the real handler does not have.
variants = [
  {"real (locked)", fn -> fn -> R.insert_metrics_flat(R.resolve(storage), batch) end end},
  {"shadow+std lock",
   fn -> fn -> R.insert_counters_dummy_locked(R.resolve(storage), batch) end end},
  {"shadow+parking_lot",
   fn -> fn -> R.insert_counters_pl_locked(R.resolve(storage), batch) end end},
  {"shadow, no lock",
   fn -> fn -> R.insert_counters_unlocked_atomic(R.resolve(storage), batch) end end}
]

IO.puts("#{schedulers} schedulers online, 6 counters/event, #{n} events/worker")
IO.puts("aggregate million events/sec\n")

for {pin?, label} <- [{false, "free-floating workers"}, {true, "workers pinned 1:1 to schedulers"}] do
  IO.puts("== #{label} ==")

  IO.puts(
    String.pad_trailing("procs", 8) <>
      Enum.map_join(variants, "", fn {name, _} -> String.pad_leading(name, 24) end) <>
      String.pad_leading("nolock/lock", 14)
  )

  for procs <- proc_counts do
    row = for {_name, body} <- variants, do: Par.throughput(body, procs, n, pin?) / 1_000_000
    [_real, locked, _pl, free] = row

    IO.puts(
      String.pad_trailing(to_string(procs), 8) <>
        Enum.map_join(row, "", &String.pad_leading(:erlang.float_to_binary(&1, decimals: 2), 24)) <>
        String.pad_leading(:erlang.float_to_binary(free / locked, decimals: 2) <> "x", 14)
    )
  end

  IO.puts("")
end
