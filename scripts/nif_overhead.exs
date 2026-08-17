import Telemetry.Metrics

# Tight-loop microbenchmark of the Rustler storage hot path, peeling back one
# layer at a time via the debug NIFs in Peep.Storage.Rustler. Reports ns/call
# with the empty-loop cost subtracted out.

defmodule Loop do
  # Each measured function is called via an explicit apply-free closure so the
  # loop body is just `fun.()` in every case, keeping loop overhead identical
  # across all measurements.
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
    # Warm up
    run(fun, n)

    1..reps
    |> Enum.map(fn _ -> time(fun, n) end)
    |> Enum.min()
  end
end

metrics = [
  counter("bench.event.count", tags: [:tag_a]),
  sum("bench.event.payload_size", tags: [:tag_a]),
  last_value("bench.event.queue_depth", tags: [:tag_a]),
  distribution("bench.event.duration",
    tags: [:tag_a],
    reporter_options: [max_value: 1_000_000, bucket_variability: 0.3]
  )
]

{:ok, _} =
  Peep.start_link(name: :bench_rs, metrics: metrics, storage: {Peep.Storage.Rustler, []})

{:ok, _} = Peep.start_link(name: :bench_striped, metrics: metrics, storage: :striped)
{:ok, _} = Peep.start_link(name: :bench_ets, metrics: metrics, storage: :default)

{rs_mod, rs_storage} = Peep.Persistent.storage(:bench_rs)
{st_mod, st_storage} = Peep.Persistent.storage(:bench_striped)
{ets_mod, ets_storage} = Peep.Persistent.storage(:bench_ets)

rs_resolved = rs_mod.resolve(rs_storage)
st_resolved = st_mod.resolve(st_storage)
ets_resolved = ets_mod.resolve(ets_storage)

itm = Peep.Persistent.ids_to_metrics(Peep.Persistent.fetch(:bench_rs))
counter_metric = elem(itm, 0)
sum_metric = elem(itm, 1)
dist_metric = elem(itm, 3)

tags = %{tag_a: "exchange_1"}

n = String.to_integer(System.get_env("N", "2000000"))
reps = String.to_integer(System.get_env("REPS", "5"))

# Prime every code path once so the slow (first-insert) branches are out of the
# way and every measured call hits its fast path.
rs_mod.insert_metric(rs_resolved, 0, counter_metric, 1, tags)
rs_mod.insert_metric(rs_resolved, 1, sum_metric, 5, tags)
rs_mod.insert_metric(rs_resolved, 3, dist_metric, 1500, tags)
st_mod.insert_metric(st_resolved, 0, counter_metric, 1, tags)
st_mod.insert_metric(st_resolved, 3, dist_metric, 1500, tags)
ets_mod.insert_metric(ets_resolved, 0, counter_metric, 1, tags)
ets_mod.insert_metric(ets_resolved, 3, dist_metric, 1500, tags)

alias Peep.Storage.Rustler, as: R

cases = [
  {"empty loop (baseline)", fn -> :ok end},
  {"debug_bare/0 (bare NIF call)", fn -> R.debug_bare() end},
  {"debug_decode_id_only/1", fn -> R.debug_decode_id_only(0) end},
  {"debug_decode_storage_plain/1", fn -> R.debug_decode_storage_plain(rs_storage) end},
  {"debug_decode_resolved_only/1", fn -> R.debug_decode_resolved_only(rs_resolved) end},
  {"debug_decode_terms_only/3", fn -> R.debug_decode_terms_only(counter_metric, 1, tags) end},
  {"debug_decode_args/5 (full arg decode)",
   fn -> R.debug_decode_args(rs_resolved, 0, counter_metric, 1, tags) end},
  {"debug_hash_tags/5 (+ term hash)",
   fn -> R.debug_hash_tags(rs_resolved, 0, counter_metric, 1, tags) end},
  {"debug_rwlock_only/5 (+ rwlock read)",
   fn -> R.debug_rwlock_only(rs_resolved, 0, counter_metric, 1, tags) end},
  {"debug_lookup_no_atomic/5 (+ hashmap lookup)",
   fn -> R.debug_lookup_no_atomic(rs_resolved, 0, counter_metric, 1, tags) end},
  {"rustler insert_metric counter", fn -> R.insert_metric(rs_resolved, 0, counter_metric, 1, tags) end},
  {"rustler insert_metric sum", fn -> R.insert_metric(rs_resolved, 1, sum_metric, 5, tags) end},
  {"rustler insert_metric dist", fn -> R.insert_metric(rs_resolved, 3, dist_metric, 1500, tags) end},
  {"striped insert_metric counter",
   fn -> st_mod.insert_metric(st_resolved, 0, counter_metric, 1, tags) end},
  {"striped insert_metric dist",
   fn -> st_mod.insert_metric(st_resolved, 3, dist_metric, 1500, tags) end},
  {"ets insert_metric counter",
   fn -> ets_mod.insert_metric(ets_resolved, 0, counter_metric, 1, tags) end},
  {"ets insert_metric dist",
   fn -> ets_mod.insert_metric(ets_resolved, 3, dist_metric, 1500, tags) end}
]

IO.puts("n = #{n} iterations, best of #{reps}\n")
IO.puts(String.pad_trailing("case", 44) <> "ns/call   net of baseline")

baseline = Loop.best_of(fn -> :ok end, n, reps)

for {name, fun} <- cases do
  ns = Loop.best_of(fun, n, reps)
  net = ns - baseline

  IO.puts(
    String.pad_trailing(name, 44) <>
      String.pad_leading(:erlang.float_to_binary(ns, decimals: 1), 7) <>
      String.pad_leading(:erlang.float_to_binary(net, decimals: 1), 12)
  )
end
