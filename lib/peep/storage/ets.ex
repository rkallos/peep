defmodule Peep.Storage.ETS do
  @moduledoc """
  Peep.Storage implementation using a single ETS table.

  A sane default for storing Peep metrics, with some simple optimizations.
  If you discover that lock contention on Peep's ETS table is high,
  consider switching to `Peep.Storage.Striped`, which reduces lock contention
  at the cost of higher memory usage.
  """
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
  def insert_metric(tid, %Metrics.Counter{} = metric, _value, %{} = tags) do
    key = {metric, tags, :erlang.system_info(:scheduler_id)}
    :ets.update_counter(tid, key, {2, 1}, {key, 0})
  end

  def insert_metric(tid, %Metrics.Sum{} = metric, value, %{} = tags) do
    key = {metric, tags, :erlang.system_info(:scheduler_id)}
    :ets.update_counter(tid, key, {2, value}, {key, 0})
  end

  def insert_metric(tid, %Metrics.LastValue{} = metric, value, %{} = tags) do
    key = {metric, tags}
    :ets.insert(tid, {key, value})
  end

  def insert_metric(tid, %Metrics.Distribution{} = metric, value, %{} = tags) do
    key = {metric, tags}

    atomics =
      case :ets.lookup(tid, key) do
        [{_key, ref}] ->
          ref

        [] ->
          # Race condition: Multiple processes could be attempting
          # to write to this key. Thankfully, :ets.insert_new/2 will break ties,
          # and concurrent writers should agree on which :atomics object to
          # increment.
          new_atomics = Storage.Atomics.new(metric)

          case :ets.insert_new(tid, {key, new_atomics}) do
            true ->
              new_atomics

            false ->
              [{_key, atomics}] = :ets.lookup(tid, key)
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
    :ets.select(tid, [{{{metric, :"$2", :_}, :"$1"}, [{:==, :"$2", tags}], [:"$1"]}])
    |> Enum.reduce(0, fn count, acc -> count + acc end)
  end

  def get_metric(tid, %Metrics.Sum{} = metric, tags) do
    :ets.select(tid, [{{{metric, :"$2", :_}, :"$1"}, [{:==, :"$2", tags}], [:"$1"]}])
    |> Enum.reduce(0, fn count, acc -> count + acc end)
  end

  def get_metric(tid, %Metrics.LastValue{} = metric, tags) do
    case :ets.lookup(tid, {metric, tags}) do
      [{_key, value}] -> value
      _ -> nil
    end
  end

  def get_metric(tid, %Metrics.Distribution{} = metric, tags) do
    case :ets.lookup(tid, {metric, tags}) do
      [{_key, atomics}] -> Storage.Atomics.values(atomics)
      _ -> nil
    end
  end

  @impl true
  def prune_tags(tid, patterns) do
    match_spec =
      patterns
      |> Enum.flat_map(fn pattern ->
        counter_or_sum_key = {:_, pattern, :_}
        dist_or_last_value_key = {:_, pattern}

        [
          {
            {counter_or_sum_key, :_},
            [],
            [true]
          },
          {
            {dist_or_last_value_key, :_},
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

  defp group_metric({{%Metrics.Counter{} = metric, tags, _}, value}, acc) do
    update_in(acc, [Access.key(metric, %{}), Access.key(tags, 0)], &(&1 + value))
  end

  defp group_metric({{%Metrics.Sum{} = metric, tags, _}, value}, acc) do
    update_in(acc, [Access.key(metric, %{}), Access.key(tags, 0)], &(&1 + value))
  end

  defp group_metric({{%Metrics.LastValue{} = metric, tags}, value}, acc) do
    put_in(acc, [Access.key(metric, %{}), Access.key(tags)], value)
  end

  defp group_metric({{%Metrics.Distribution{} = metric, tags}, atomics}, acc) do
    put_in(acc, [Access.key(metric, %{}), Access.key(tags)], Storage.Atomics.values(atomics))
  end
end
