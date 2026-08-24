defmodule CustomBatchedStorage do
  @moduledoc """
  Custom implementation of Peep.Storage for testing purposes. Implements the
  optional `insert_metrics/3` and `register_metrics/2` callbacks, and keeps what
  `register_metrics/2` receives for `registered_metrics/1`.
  """
  @behaviour Peep.Storage

  require Peep.Persistent
  require Peep.Storage.Atomics

  alias Peep.Storage
  alias Telemetry.Metrics

  @registered_key :registered_metrics

  @impl true
  def new(_opts) do
    :ets.new(__MODULE__, [:public, write_concurrency: true])
  end

  @impl true
  def resolve(tid), do: tid

  @impl true
  def register_metrics(tid, ids_to_metrics) do
    :ets.insert(tid, {@registered_key, ids_to_metrics})
    :ok
  end

  def registered_metrics(tid) do
    :ets.lookup_element(tid, @registered_key, 2, nil)
  end

  @impl true
  def storage_size(tid) do
    %{
      size: :ets.info(tid, :size),
      memory: :ets.info(tid, :memory) * :erlang.system_info(:wordsize)
    }
  end

  @impl true
  def insert_metrics(tid, tag_results, batch) do
    insert_batch(tid, tag_results, batch, %{})
  end

  defp insert_batch(_tid, _tag_results, [], _seen), do: :ok

  defp insert_batch(tid, tag_results, [{id, metric, value, tag_idx} | rest], seen) do
    {tags, seen} =
      case seen do
        %{^tag_idx => tags} ->
          {tags, seen}

        _ ->
          tags = elem(tag_results, tag_idx)
          {tags, Map.put(seen, tag_idx, tags)}
      end

    insert(tid, id, metric, value, tags)
    insert_batch(tid, tag_results, rest, seen)
  end

  defp insert(tid, id, %Metrics.Counter{}, _value, tags) do
    key = {id, tags}
    :ets.update_counter(tid, key, {2, 1}, {key, 0})
  end

  defp insert(tid, id, %Metrics.Sum{}, value, tags) do
    key = {id, tags}
    :ets.update_counter(tid, key, {2, value}, {key, 0})
  end

  defp insert(tid, id, %Metrics.LastValue{}, value, tags) do
    :ets.insert(tid, {{id, tags}, value})
  end

  defp insert(tid, id, %Metrics.Distribution{} = metric, value, tags) do
    key = {id, tags}

    atomics =
      case :ets.lookup_element(tid, key, 2, nil) do
        nil ->
          new_atomics = Storage.Atomics.new(metric)

          if :ets.insert_new(tid, {key, new_atomics}) do
            new_atomics
          else
            :ets.lookup_element(tid, key, 2, nil)
          end

        existing ->
          existing
      end

    Storage.Atomics.insert(atomics, value)
  end

  @impl true
  def get_all_metrics(tid, Peep.Persistent.persistent(ids_to_metrics: itm)) do
    group_metrics(:ets.tab2list(tid), itm, %{})
  end

  @impl true
  def prune_tags(tid, patterns) do
    match_spec = for pattern <- patterns, do: {{{:_, pattern}, :_}, [], [true]}
    :ets.select_delete(tid, match_spec)
    :ok
  end

  defp group_metrics([], _itm, acc), do: acc

  defp group_metrics([entry | rest], itm, acc) do
    group_metrics(rest, itm, group_metric(entry, itm, acc))
  end

  # Skip the reserved register_metrics/2 bookkeeping entry.
  defp group_metric({@registered_key, _ids_to_metrics}, _itm, acc), do: acc

  defp group_metric({{id, tags}, value}, itm, acc) do
    metric = elem(itm, id)
    path = [Access.key(metric, %{}), Access.key(tags)]

    case metric do
      %Metrics.Distribution{} ->
        put_in(acc, path, Storage.Atomics.values(value))

      _ ->
        put_in(acc, path, value)
    end
  end
end
