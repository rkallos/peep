defmodule Peep.Storage do
  @moduledoc false
  alias __MODULE__
  alias Telemetry.Metrics

  @spec new(atom) :: :ets.tid()
  def new(name) do
    opts = [
      :public,
      :named_table,
      # Enabling read_concurrency makes switching between reads and writes
      # more expensive. The goal is to ruthlessly optimize writes, even at
      # the cost of read performance.
      read_concurrency: false,
      write_concurrency: true,
      decentralized_counters: true
    ]

    :ets.new(name, opts)
  end

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

  def get_all_metrics(tid) do
    :ets.tab2list(tid)
    |> group_metrics(%{})
  end

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
