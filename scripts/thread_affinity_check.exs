# Checks the linchpin of a genuinely lock-free per-scheduler storage design:
#
#   1. Does a process spawned with `spawn_opt(scheduler: K)` always execute its
#      NIF on the same OS thread? (If so, a thread_local shard index is a stable
#      identity for "scheduler K's storage".)
#   2. Is that thread always a *normal* scheduler thread, never a dirty one?
#   3. Do distinct schedulers get distinct threads, i.e. is the mapping 1:1?
#
# If all three hold, collection can be dispatched to a process pinned to each
# scheduler, which then reads that thread's storage with no lock and no atomics -
# because no other thread can be touching it.

alias Peep.Storage.Rustler, as: R

# ERL_NIF_THR_UNDEFINED = 0, NORMAL_SCHEDULER = 1, DIRTY_CPU = 2, DIRTY_IO = 3
thread_type_name = fn
  0 -> "undefined"
  1 -> "normal_scheduler"
  2 -> "dirty_cpu"
  3 -> "dirty_io"
  other -> "unknown(#{other})"
end

schedulers = :erlang.system_info(:schedulers)
IO.puts("#{schedulers} schedulers configured\n")

# Ask each scheduler, repeatedly and from freshly spawned processes each time,
# which shard its thread owns.
observations =
  for k <- 1..schedulers, into: %{} do
    results =
      for _ <- 1..25 do
        parent = self()

        :erlang.spawn_opt(
          fn ->
            # Burn reductions first, so the process is preempted at least once
            # and would migrate if pinning were not honoured.
            Enum.reduce(1..5_000, 0, fn i, acc -> acc + i end)
            send(parent, {:result, R.debug_thread_shard(), :erlang.system_info(:scheduler_id)})
          end,
          [{:scheduler, k}]
        )

        receive do: ({:result, shard_and_type, sched} -> {shard_and_type, sched})
      end

    {k, Enum.uniq(results)}
  end

IO.puts(String.pad_trailing("scheduler", 12) <> String.pad_trailing("distinct observations", 24) <> "shard / thread type / scheduler_id")

stable? =
  Enum.reduce(1..schedulers, true, fn k, acc ->
    uniq = observations[k]

    detail =
      Enum.map_join(uniq, ", ", fn {{shard, type}, sched} ->
        "#{shard} / #{thread_type_name.(type)} / #{sched}"
      end)

    IO.puts(String.pad_trailing(to_string(k), 12) <> String.pad_trailing(to_string(length(uniq)), 24) <> detail)
    acc and length(uniq) == 1
  end)

shards = for k <- 1..schedulers, [{{shard, _type}, _sched}] <- [observations[k]], do: shard
all_normal? = Enum.all?(1..schedulers, fn k -> match?([{{_, 1}, _}], observations[k]) end)
one_to_one? = length(Enum.uniq(shards)) == length(shards)

IO.puts("""

pinned process always hits the same thread: #{stable?}
always a normal scheduler thread:           #{all_normal?}
scheduler -> thread mapping is 1:1:         #{one_to_one?}
""")

# And the converse hazard: without pinning, does a process's scheduler change
# between `resolve/1` and a later call in the same function body? That is what
# makes a scheduler_id read in Elixir unsafe to use as an exclusive-access token.
migrations =
  for _ <- 1..200 do
    Task.async(fn ->
      Enum.reduce(1..2_000, {0, 0}, fn i, {acc, migrated} ->
        before = :erlang.system_info(:scheduler_id)
        # Stand-in for the work handle_event/4 does between resolve/1 and the
        # insert: compute tags, extract measurements, build the batch.
        _ = Map.take(%{a: 1, b: 2, c: 3}, [:a, :b])
        after_ = :erlang.system_info(:scheduler_id)
        {acc + i, migrated + if(before != after_, do: 1, else: 0)}
      end)
    end)
  end
  |> Enum.map(&Task.await(&1, 30_000))
  |> Enum.map(fn {_, migrated} -> migrated end)
  |> Enum.sum()

IO.puts("scheduler changed mid-handler #{migrations} times out of 400000 samples")
