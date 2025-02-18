defmodule Peep.Storage.ETSPreHashed do
  @moduledoc false
  alias Peep.Storage
  alias Telemetry.Metrics

  @behaviour Peep.Storage

  @spec new() :: :ets.tid()
  @impl true
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

  @impl true
  def storage_size(tid) do
    %{
      size: :ets.info(tid, :size),
      memory: :ets.info(tid, :memory) * :erlang.system_info(:wordsize)
    }
  end

  @impl true
  def insert_metric(tid, metric, value, tags) do
    insert_metric(tid, metric, :erlang.phash2(metric), value, tags)
  end

  @impl true
  def insert_metric(tid, %Metrics.Counter{} = metric, hash, _value, %{} = tags) do
    key = {hash, tags, :erlang.system_info(:scheduler_id)}
    :ets.update_counter(tid, key, {3, 1}, {key, metric, 0})
  end

  def insert_metric(tid, %Metrics.Sum{} = metric, hash, value, %{} = tags) do
    key = {hash, tags, :erlang.system_info(:scheduler_id)}
    :ets.update_counter(tid, key, {3, value}, {key, metric, 0})
  end

  def insert_metric(tid, %Metrics.LastValue{} = metric, hash, value, %{} = tags) do
    key = {hash, tags}
    :ets.insert(tid, {key, metric, value})
  end

  def insert_metric(tid, %Metrics.Distribution{} = metric, hash, value, %{} = tags) do
    hashed_tags = :erlang.phash2(tags)
    key = {hash, hashed_tags}

    atomics =
      case :ets.lookup(tid, key) do
        [{_key, _metric, _tags, ref}] ->
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
              [{_key, _metric, _tags, atomics}] = :ets.lookup(tid, key)
              atomics
          end
      end

    Storage.Atomics.insert(atomics, value)
  end

  @impl true
  def get_all_metrics(tid) do
    :ets.tab2list(tid)
    |> group_metrics(%{})
  end

  @impl true
  def get_metric(tid, metrics, tags) when is_list(tags),
    do: get_metric(tid, metrics, Map.new(tags))

  def get_metric(tid, %Metrics.Counter{} = metric, tags) do
    hash = :erlang.phash2(metric)

    :ets.select(tid, [{{{hash, :"$2", :_}, :_, :"$1"}, [{:==, :"$2", tags}], [:"$1"]}])
    |> Enum.reduce(0, fn count, acc -> count + acc end)
  end

  def get_metric(tid, %Metrics.Sum{} = metric, tags) do
    hash = :erlang.phash2(metric)

    :ets.select(tid, [{{{hash, :"$2", :_}, :_, :"$1"}, [{:==, :"$2", tags}], [:"$1"]}])
    |> Enum.reduce(0, fn count, acc -> count + acc end)
  end

  def get_metric(tid, %Metrics.LastValue{} = metric, tags) do
    hash = :erlang.phash2(metric)

    case :ets.lookup(tid, {hash, tags}) do
      [{_key, ^metric, value}] -> value
      _ -> nil
    end
  end

  def get_metric(tid, %Metrics.Distribution{} = metric, tags) do
    hash = :erlang.phash2(metric)
    hashed_tags = :erlang.phash2(tags)
    key = {hash, hashed_tags}

    case :ets.lookup(tid, key) do
      [{_key, ^metric, ^tags, atomics}] -> Storage.Atomics.values(atomics)
      _ -> nil
    end
  end

  @impl true
  def prune_tags(tid, patterns) do
    match_spec =
      patterns
      |> Enum.flat_map(fn pattern ->
        [
          # counter, sum
          {
            {{:_, pattern, :_}, :_, :_},
            [],
            [true]
          },
          # last value
          {
            {{:_, pattern}, :_, :_},
            [],
            [true]
          },
          # dist
          {
            {:_, :_, pattern, :_},
            [],
            [true]
          }
        ]
      end)

    :ets.select_delete(tid, match_spec)
    :ok
  end

  defp group_metrics([], acc) do
    acc
  end

  defp group_metrics([metric | rest], acc) do
    acc2 = group_metric(metric, acc)
    group_metrics(rest, acc2)
  end

  defp group_metric({{_hash, tags, _}, %Metrics.Counter{} = metric, value}, acc) do
    update_in(acc, [Access.key(metric, %{}), Access.key(tags, 0)], &(&1 + value))
  end

  defp group_metric({{_hash, tags, _}, %Metrics.Sum{} = metric, value}, acc) do
    update_in(acc, [Access.key(metric, %{}), Access.key(tags, 0)], &(&1 + value))
  end

  defp group_metric({{_hash, tags}, %Metrics.LastValue{} = metric, value}, acc) do
    put_in(acc, [Access.key(metric, %{}), Access.key(tags)], value)
  end

  defp group_metric({{_hash, _hashed_tags}, %Metrics.Distribution{} = metric, tags, atomics}, acc) do
    put_in(acc, [Access.key(metric, %{}), Access.key(tags)], Storage.Atomics.values(atomics))
  end
end
