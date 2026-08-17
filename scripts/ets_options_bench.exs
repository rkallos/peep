import Telemetry.Metrics

# The striped profile spends ~19% of its cycles in ethr_rwmutex_rlock/runlock/
# rwlock/rwunlock and rwmutex_freqread_rlock. Peep.Storage.Striped gives every
# scheduler its own table, so those tables are effectively uncontended - which
# raises the question of whether `write_concurrency: true` +
# `decentralized_counters: true` is buying anything, or just paying for
# contention-spreading machinery that has no contention to spread.
#
# Reproduces Striped's exact access pattern - one table per worker,
# `:ets.update_counter(tid, {id, tags}, {2, 1}, {key, 0})` - across option sets.

defmodule Loop do
  def run(_fun, 0), do: :ok

  def run(fun, n) do
    fun.()
    run(fun, n - 1)
  end
end

defmodule Hammer do
  # Six counters per iteration, matching the 6-metric event the other
  # benchmarks use.
  def bump(tid, keys) do
    Enum.each(keys, fn key -> :ets.update_counter(tid, key, {2, 1}, {key, 0}) end)
  end
end

defmodule Par do
  # Each worker gets its own table, mirroring one scheduler's private table.
  def throughput(opts, procs, n, keys) do
    parent = self()

    pids =
      for i <- 1..procs do
        :erlang.spawn_opt(
          fn ->
            tid = :ets.new(:bench, opts)
            Hammer.bump(tid, keys)
            Loop.run(fn -> Hammer.bump(tid, keys) end, div(n, 10))
            send(parent, {:ready, self()})
            receive do: (:go -> :ok)

            t0 = :erlang.monotonic_time(:nanosecond)
            Loop.run(fn -> Hammer.bump(tid, keys) end, n)
            t1 = :erlang.monotonic_time(:nanosecond)
            send(parent, {:done, self(), t1 - t0})
          end,
          [:link, {:scheduler, rem(i - 1, :erlang.system_info(:schedulers)) + 1}]
        )
      end

    for pid <- pids, do: receive(do: ({:ready, ^pid} -> :ok))
    for pid <- pids, do: send(pid, :go)
    elapsed = for pid <- pids, do: receive(do: ({:done, ^pid, ns} -> ns))

    procs * n / (Enum.max(elapsed) / 1_000_000_000)
  end
end

tags_a = %{tag_a: "exchange_1"}
tags_ab = %{tag_a: "exchange_1", tag_b: "channel_2"}
keys = [{0, tags_a}, {1, tags_a}, {2, tags_ab}, {3, tags_a}, {4, tags_a}, {5, tags_ab}]

option_sets = [
  {"striped today", [:public, read_concurrency: false, write_concurrency: true, decentralized_counters: true]},
  {"wc:true dc:false", [:public, read_concurrency: false, write_concurrency: true, decentralized_counters: false]},
  {"wc:auto", [:public, read_concurrency: false, write_concurrency: :auto]},
  {"wc:false", [:public, read_concurrency: false, write_concurrency: false]},
  {"private wc:false", [:private, read_concurrency: false, write_concurrency: false]}
]

n = String.to_integer(System.get_env("N", "300000"))
schedulers = :erlang.system_info(:schedulers_online)

proc_counts =
  System.get_env("PROCS", "1,#{div(schedulers, 2)},#{schedulers}")
  |> String.split(",")
  |> Enum.map(&String.to_integer/1)
  |> Enum.uniq()

IO.puts("#{schedulers} schedulers, one private table per worker, 6 update_counter/iteration")
IO.puts("aggregate throughput, million iterations/sec\n")

IO.puts(
  String.pad_trailing("workers", 10) <>
    Enum.map_join(option_sets, "", fn {name, _} -> String.pad_leading(name, 19) end)
)

for procs <- proc_counts do
  row = for {_name, opts} <- option_sets, do: Par.throughput(opts, procs, n, keys) / 1_000_000

  IO.puts(
    String.pad_trailing(to_string(procs), 10) <>
      Enum.map_join(row, "", &String.pad_leading(:erlang.float_to_binary(&1, decimals: 2), 19))
  )
end

_ = counter("unused.metric", tags: [])
