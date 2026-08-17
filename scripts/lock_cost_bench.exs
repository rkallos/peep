import Telemetry.Metrics

# Prices the synchronization on the Counter hot path, to size the "one Storage
# per scheduler thread, lock-free, non-atomic" idea:
#
#   real            - today's path: per-shard RwLock + AtomicI64 RMW
#   unlocked_atomic - same hash/probe/tags_match, no RwLock, still atomic
#   unlocked_plain  - no RwLock, plain `i64 += 1`
#
# real - unlocked_atomic  = what the RwLock costs
# unlocked_atomic - plain = what the atomic RMW costs
#
# Plus the `resolve/1` side: today's `:erlang.system_info(:scheduler_id)` +
# `{resource, shard}` tuple decode, against a Rust thread_local shard.

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

alias Peep.Storage.Rustler, as: R

metrics = for i <- 1..6, do: counter("lock.bench.c#{i}", tags: [:tag_a])

{:ok, _} = Peep.start_link(name: :lock_bench, metrics: metrics, storage: {Peep.Storage.Rustler, []})

{R, storage} = Peep.Persistent.storage(:lock_bench)
resolved = R.resolve(storage)
itm = Peep.Persistent.ids_to_metrics(Peep.Persistent.fetch(:lock_bench))
metric = elem(itm, 0)

tags = %{tag_a: "exchange_1"}

n = String.to_integer(System.get_env("N", "2000000"))
reps = String.to_integer(System.get_env("REPS", "7"))

# Prime every path's first-insert branch.
R.insert_metric(resolved, 0, metric, 1, tags)
R.insert_counter_unlocked_atomic(resolved, 0, tags)
R.insert_counter_unlocked_plain(resolved, 0, tags)
R.insert_counter_thread_local(storage, 0, tags)

batch = for id <- 0..5, do: {id, 1, tags}
R.insert_metrics_flat(resolved, batch)
R.insert_counters_unlocked_plain(resolved, batch)

single = [
  {"real (RwLock + atomic)", fn -> R.insert_metric(resolved, 0, metric, 1, tags) end},
  {"unlocked, atomic value", fn -> R.insert_counter_unlocked_atomic(resolved, 0, tags) end},
  {"unlocked, plain i64", fn -> R.insert_counter_unlocked_plain(resolved, 0, tags) end},
  {"real, thread_local shard", fn -> R.insert_counter_thread_local(storage, 0, tags) end}
]

resolve_cases = [
  {"empty loop", fn -> :ok end},
  {"Rustler.resolve/1", fn -> R.resolve(storage) end},
  {"system_info(:scheduler_id)", fn -> :erlang.system_info(:scheduler_id) end},
  {"debug_thread_local/1 (NIF)", fn -> R.debug_thread_local(storage) end},
  {"debug_decode_storage_plain/1", fn -> R.debug_decode_storage_plain(storage) end},
  {"debug_decode_resolved_only/1", fn -> R.debug_decode_resolved_only(resolved) end}
]

batched = [
  {"real batched (6 counters)", fn -> R.insert_metrics_flat(resolved, batch) end},
  {"unlocked plain batched (6)", fn -> R.insert_counters_unlocked_plain(resolved, batch) end}
]

IO.puts("n = #{n}, best of #{reps}\n")
IO.puts("== single counter insert ==")
IO.puts(String.pad_trailing("variant", 32) <> String.pad_leading("ns/call", 10))

baseline = Loop.best_of(fn -> :ok end, n, reps)

single_results =
  for {name, fun} <- single do
    ns = Loop.best_of(fun, n, reps) - baseline
    IO.puts(String.pad_trailing(name, 32) <> String.pad_leading(:erlang.float_to_binary(ns, decimals: 1), 10))
    {name, ns}
  end

[{_, real}, {_, unlocked_atomic}, {_, unlocked_plain}, {_, thread_local}] = single_results

IO.puts("""

  RwLock acquire+release: #{:erlang.float_to_binary(real - unlocked_atomic, decimals: 1)} ns
  atomic RMW vs plain +=: #{:erlang.float_to_binary(unlocked_atomic - unlocked_plain, decimals: 1)} ns
  both together:          #{:erlang.float_to_binary(real - unlocked_plain, decimals: 1)} ns \
(#{:erlang.float_to_binary((real - unlocked_plain) / real * 100, decimals: 1)}% of the insert)
  thread_local vs tuple:  #{:erlang.float_to_binary(real - thread_local, decimals: 1)} ns\
""")

IO.puts("\n== batched, 6 counters/event ==")
IO.puts(String.pad_trailing("variant", 32) <> String.pad_leading("ns/event", 10) <> String.pad_leading("ns/metric", 12))

for {name, fun} <- batched do
  ns = Loop.best_of(fun, n, reps) - baseline

  IO.puts(
    String.pad_trailing(name, 32) <>
      String.pad_leading(:erlang.float_to_binary(ns, decimals: 1), 10) <>
      String.pad_leading(:erlang.float_to_binary(ns / 6, decimals: 1), 12)
  )
end

IO.puts("\n== resolve-side costs ==")
IO.puts(String.pad_trailing("variant", 32) <> String.pad_leading("ns/call", 10))

for {name, fun} <- resolve_cases do
  ns = Loop.best_of(fun, n, reps) - baseline
  IO.puts(String.pad_trailing(name, 32) <> String.pad_leading(:erlang.float_to_binary(ns, decimals: 1), 10))
end
