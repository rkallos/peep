defmodule Peep.Storage.FastDist do
  @moduledoc false
  alias Peep.Storage
  alias Peep.Storage.ETS
  alias Telemetry.Metrics

  @behaviour Peep.Storage

  def new() do
    opts = [
      :public,
      # Enabling read_concurrency makes switching between reads and writes
      # more expensive. The goal is to ruthlessly optimize writes, even at
      # the cost of read performance.
      read_concurrency: false,
      write_concurrency: true,
      decentralized_counters: true
    ]

    :ets.new(__MODULE__, opts)
  end

  defdelegate storage_size(tid), to: ETS
  defdelegate get_all_metrics(tid), to: ETS
  defdelegate get_metric(tid, metric, labels), to: ETS

  def insert_metric(tid, metric, value, tags) do
    insert_metric(tid, metric, :erlang.phash2(metric), value, tags)
  end

  def insert_metric(tid, %Metrics.Distribution{} = metric, hash, value, %{} = tags) do
    hashed_tags = :erlang.phash2(tags)
    key = {hash, hashed_tags}

    atomics =
      case lookup_atomics(tid, key) do
        [ref] ->
          ref

        [] ->
          # Race condition: Multiple processes could be attempting
          # to write to this key. Thankfully, :ets.insert_new/2 will break ties,
          # and concurrent writers should agree on which :atomics object to
          # increment.
          new_atomics = Storage.Atomics.new(metric)

          case :ets.insert_new(tid, {key, metric, tags, new_atomics}) do
            true ->
              new_atomics

            false ->
              [atomics] = lookup_atomics(tid, key)
              atomics
          end
      end

    Storage.Atomics.insert(atomics, value)
  end

  def insert_metric(tid, metric, hash, value, tags) do
    ETS.insert_metric(tid, metric, hash, value, tags)
  end

  defp lookup_atomics(tid, {hashed_metric, hashed_tags}) do
    atomics = :"$1"

    match_spec = [
      {
        {{hashed_metric, hashed_tags}, :_, :_, atomics},
        [],
        [atomics]
      }
    ]

    :ets.select(tid, match_spec)
  end
end
