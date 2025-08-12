defmodule Peep.Storage.Striped do
  @moduledoc """
  Peep.Storage implementation using an ETS table per BEAM scheduler thread.

  Offers less lock contention than `Peep.Storage.ETS`, at the cost of higher
  memory usage. Recommended when executing thousands of metrics per second.
  """
  alias Telemetry.Metrics
  alias Peep.Storage

  @behaviour Peep.Storage

  @typep tids() :: tuple()

  @compile :inline

  @spec new() :: tids()
  @impl true
  def new() do
    opts = [
      :public,
      read_concurrency: false,
      write_concurrency: true,
      decentralized_counters: true
    ]

    n_schedulers = :erlang.system_info(:schedulers_online)
    List.to_tuple(Enum.map(1..n_schedulers, fn _ -> :ets.new(__MODULE__, opts) end))
  end

  @impl true
  def storage_size(tids) do
    {size, memory} =
      tids
      |> Tuple.to_list()
      |> Enum.reduce({0, 0}, fn tid, {size, memory} ->
        {size + :ets.info(tid, :size), memory + :ets.info(tid, :memory)}
      end)

    %{
      size: size,
      memory: memory * :erlang.system_info(:wordsize)
    }
  end

  @impl true
  def insert_metric(tids, id, %Metrics.Counter{}, _value, %{} = tags) do
    tid = get_tid(tids)
    key = {id, tags}
    :ets.update_counter(tid, key, {2, 1}, {key, 0})
  end

  def insert_metric(tids, id, %Metrics.Sum{}, value, %{} = tags) do
    tid = get_tid(tids)
    key = {id, tags}
    :ets.update_counter(tid, key, {2, value}, {key, 0})
  end

  def insert_metric(tids, id, %Metrics.LastValue{}, value, %{} = tags) do
    tid = get_tid(tids)
    now = System.monotonic_time()
    key = {id, tags}
    :ets.insert(tid, {key, {now, value}})
  end

  def insert_metric(tids, id, %Metrics.Distribution{} = metric, value, %{} = tags) do
    tid = get_tid(tids)
    key = {id, tags}

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

  defp get_tid(tids) do
    scheduler_id = :erlang.system_info(:scheduler_id)
    elem(tids, scheduler_id - 1)
  end

  @impl true
  def get_metric(tids, id, %Metrics.Counter{}, tags) do
    key = {id, tags}

    for tid <- Tuple.to_list(tids), reduce: 0 do
      acc ->
        case :ets.lookup(tid, key) do
          [] -> acc
          [{_, value}] -> acc + value
        end
    end
  end

  def get_metric(tids, id, %Metrics.Sum{}, tags) do
    key = {id, tags}

    for tid <- Tuple.to_list(tids), reduce: 0 do
      acc ->
        case :ets.lookup(tid, key) do
          [] -> acc
          [{_, value}] -> acc + value
        end
    end
  end

  def get_metric(tids, id, %Metrics.LastValue{}, tags) do
    key = {id, tags}

    {_ts, value} =
      for tid <- Tuple.to_list(tids), reduce: nil do
        acc ->
          case :ets.lookup(tid, key) do
            [] ->
              acc

            [{_, {_, _} = b}] ->
              if acc do
                max(acc, b)
              else
                b
              end
          end
      end

    value
  end

  def get_metric(tids, id, %Metrics.Distribution{}, tags) do
    key = {id, tags}

    merge_fun = fn _k, v1, v2 -> v1 + v2 end

    for tid <- Tuple.to_list(tids), reduce: nil do
      acc ->
        case :ets.lookup(tid, key) do
          [] ->
            acc

          [{_key, atomics}] ->
            values = Storage.Atomics.values(atomics)

            if acc do
              Map.merge(acc, values, merge_fun)
            else
              values
            end
        end
    end
  end

  @impl true
  def prune_tags(tids, patterns) do
    match_spec =
      patterns
      |> Enum.map(fn pattern ->
        {
          {{:_, pattern}, :_},
          [],
          [true]
        }
      end)

    for tid <- Tuple.to_list(tids) do
      :ets.select_delete(tid, match_spec)
    end

    :ok
  end

  @impl true
  def get_all_metrics(tids, %Peep.Persistent{ids_to_metrics: itm}) do
    acc = get_all_metrics2(Tuple.to_list(tids), itm, %{})
    remove_timestamps_from_last_values(acc)
  end

  defp get_all_metrics2([], _itm, acc), do: acc

  defp get_all_metrics2([tid | rest], itm, acc) do
    acc = add_metrics(:ets.tab2list(tid), itm, acc)
    get_all_metrics2(rest, itm, acc)
  end

  defp add_metrics([], _itm, acc), do: acc

  defp add_metrics([metric | rest], itm, acc) do
    acc2 = add_metric(metric, itm, acc)
    add_metrics(rest, itm, acc2)
  end

  defp add_metric({{id, _tags}, _value} = kv, itm, acc) do
    %{^id => metric} = itm
    add_metric2(kv, metric, acc)
  end

  defp add_metric2({{_id, tags}, value}, %Metrics.Counter{} = metric, acc) do
    path = [Access.key(metric, %{}), Access.key(tags, 0)]
    update_in(acc, path, &(&1 + value))
  end

  defp add_metric2({{_id, tags}, value}, %Metrics.Sum{} = metric, acc) do
    path = [Access.key(metric, %{}), Access.key(tags, 0)]
    update_in(acc, path, &(&1 + value))
  end

  defp add_metric2({{_id, tags}, {_, _} = a}, %Metrics.LastValue{} = metric, acc) do
    path = [
      Access.key(:last_values, %{}),
      Access.key(metric, %{}),
      Access.key(tags, a)
    ]

    update_in(acc, path, fn {_, _} = b -> max(a, b) end)
  end

  defp add_metric2({{_id, tags}, atomics}, %Metrics.Distribution{} = metric, acc) do
    path = [
      Access.key(metric, %{}),
      Access.key(tags, %{})
    ]

    values = Storage.Atomics.values(atomics)

    update_in(acc, path, fn m1 -> Map.merge(m1, values, fn _k, v1, v2 -> v1 + v2 end) end)
  end

  defp remove_timestamps_from_last_values(%{last_values: lvs} = metrics) do
    last_value_metrics =
      for {metric, tags_to_values} <- lvs,
          {tags, {_ts, value}} <- tags_to_values,
          reduce: %{} do
        acc ->
          put_in(acc, [Access.key(metric, %{}), Access.key(tags)], value)
      end

    metrics
    |> Map.delete(:last_values)
    |> Map.merge(last_value_metrics)
  end

  defp remove_timestamps_from_last_values(metrics), do: metrics
end
