defmodule Peep.Storage.Striped do
  @moduledoc """
  Peep.Storage implementation using an ETS table per BEAM scheduler thread.

  Offers less lock contention than `Peep.Storage.ETS`, at the cost of higher
  memory usage. Recommended when executing thousands of metrics per second.
  """
  alias Telemetry.Metrics
  alias Peep.Storage

  @behaviour Peep.Storage

  @typep tids() :: %{pos_integer() => :ets.tid()}

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
    Map.new(1..n_schedulers, fn i -> {i, :ets.new(__MODULE__, opts)} end)
  end

  @impl true
  def storage_size(tids) do
    size = Enum.reduce(tids, 0, fn {_, tid}, acc -> acc + :ets.info(tid, :size) end)
    memory = Enum.reduce(tids, 0, fn {_, tid}, acc -> acc + :ets.info(tid, :memory) end)

    %{
      size: size,
      memory: memory * :erlang.system_info(:wordsize)
    }
  end

  @impl true
  def insert_metric(tids, %Metrics.Counter{} = metric, _value, %{} = tags) do
    tid = get_tid(tids)
    key = {metric, tags}
    :ets.update_counter(tid, key, {2, 1}, {key, 0})
  end

  def insert_metric(tids, %Metrics.Sum{} = metric, value, %{} = tags) do
    tid = get_tid(tids)
    key = {metric, tags}
    :ets.update_counter(tid, key, {2, value}, {key, 0})
  end

  def insert_metric(tids, %Metrics.LastValue{} = metric, value, %{} = tags) do
    tid = get_tid(tids)
    now = System.monotonic_time()
    key = {metric, tags}
    :ets.insert(tid, {key, {now, value}})
  end

  def insert_metric(tids, %Metrics.Distribution{} = metric, value, %{} = tags) do
    tid = get_tid(tids)
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

  defp get_tid(tids) do
    scheduler_id = :erlang.system_info(:scheduler_id)
    %{^scheduler_id => tid} = tids
    tid
  end

  @impl true
  def get_metric(tids, metrics, tags) when is_list(tags),
    do: get_metric(tids, metrics, Map.new(tags))

  def get_metric(tids, %Metrics.Counter{} = metric, tags) do
    key = {metric, tags}

    for tid <- Map.values(tids), reduce: 0 do
      acc ->
        case :ets.lookup(tid, key) do
          [] -> acc
          [{_, value}] -> acc + value
        end
    end
  end

  def get_metric(tids, %Metrics.Sum{} = metric, tags) do
    key = {metric, tags}

    for tid <- Map.values(tids), reduce: 0 do
      acc ->
        case :ets.lookup(tid, key) do
          [] -> acc
          [{_, value}] -> acc + value
        end
    end
  end

  def get_metric(tids, %Metrics.LastValue{} = metric, tags) do
    key = {metric, tags}

    {_ts, value} =
      for tid <- Map.values(tids), reduce: nil do
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

  def get_metric(tids, %Metrics.Distribution{} = metric, tags) do
    key = {metric, tags}

    merge_fun = fn _k, v1, v2 -> v1 + v2 end

    for tid <- Map.values(tids), reduce: nil do
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
        metric_key = {:_, pattern}

        {
          {metric_key, :_},
          [],
          [true]
        }
      end)

    for {_, tid} <- tids do
      :ets.select_delete(tid, match_spec)
    end

    :ok
  end

  @impl true
  def get_all_metrics(tids) do
    acc = get_all_metrics(Map.values(tids), %{})
    remove_timestamps_from_last_values(acc)
  end

  defp get_all_metrics([], acc), do: acc

  defp get_all_metrics([tid | rest], acc) do
    acc = add_metrics(:ets.tab2list(tid), acc)
    get_all_metrics(rest, acc)
  end

  defp add_metrics([], acc), do: acc

  defp add_metrics([metric | rest], acc) do
    acc2 = add_metric(metric, acc)
    add_metrics(rest, acc2)
  end

  defp add_metric({{%Metrics.Counter{} = metric, tags}, value}, acc) do
    path = [Access.key(metric, %{}), Access.key(tags, 0)]
    update_in(acc, path, &(&1 + value))
  end

  defp add_metric({{%Metrics.Sum{} = metric, tags}, value}, acc) do
    path = [Access.key(metric, %{}), Access.key(tags, 0)]
    update_in(acc, path, &(&1 + value))
  end

  defp add_metric({{%Metrics.LastValue{} = metric, tags}, {_, _} = a}, acc) do
    path = [
      Access.key(:last_values, %{}),
      Access.key(metric, %{}),
      Access.key(tags, a)
    ]

    update_in(acc, path, fn {_, _} = b -> max(a, b) end)
  end

  defp add_metric({{%Metrics.Distribution{} = metric, tags}, atomics}, acc) do
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
