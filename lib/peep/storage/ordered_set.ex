defmodule Peep.Storage.OrderedSet do
  @behaviour Peep.Storage

  alias Peep.Storage
  alias Telemetry.Metrics

  @spec new() :: :ets.tid()
  @impl true
  def new() do
    opts = [
      :public,
      :ordered_set,
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
  defdelegate storage_size(tid), to: Storage.ETS

  def insert_metric(tid, metric, value, tags) do
    insert_metric(tid, metric, :erlang.phash2(metric), value, tags)
  end

  @impl true
  def insert_metric(tid, %Metrics.Counter{} = metric, hash, _value, %{} = tags) do
    key = make_key(hash, metric, tags)
    :ets.update_counter(tid, key, {3, 1}, {key, metric, 0})
  end

  def insert_metric(tid, %Metrics.Sum{} = metric, hash, value, %{} = tags) do
    key = make_key(hash, metric, tags)
    :ets.update_counter(tid, key, {3, value}, {key, metric, 0})
  end

  def insert_metric(tid, %Metrics.LastValue{} = metric, hash, value, %{} = tags) do
    key = make_key(hash, metric, tags)
    :ets.update_element(tid, key, {3, value}, {key, metric, value})
  end

  def insert_metric(tid, %Metrics.Distribution{} = metric, hash, value, %{} = tags) do
    key = make_key(hash, metric, tags)

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

          case :ets.insert_new(tid, {key, metric, new_atomics}) do
            true ->
              new_atomics

            false ->
              [atomics] = lookup_atomics(tid, key)
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

  def get_metric(tid, %Metrics.Counter{event_name: event_name} = metric, tags) do
    hash = :erlang.phash2(metric)
    match_value = :"$1"
    match_tags = :"$2"

    spec = [
      {
        {{hash, match_tags}, :_, match_value},
        [{:==, match_tags, tags}],
        [match_value]
      }
    ]

    sum(:ets.select(tid, spec))
  end

  def get_metric(tid, %Metrics.Sum{event_name: event_name} = metric, tags) do
    hash = :erlang.phash2(metric)
    match_value = :"$1"
    match_tags = :"$2"

    spec = [
      {
        {{hash, match_tags}, :_, match_value},
        [{:==, match_tags, tags}],
        [match_value]
      }
    ]

    sum(:ets.select(tid, spec))
  end

  def get_metric(tid, %Metrics.LastValue{event_name: event_name} = metric, tags) do
    hash = :erlang.phash2(metric)
    match_value = :"$1"
    match_tags = :"$2"

    spec = [
      {
        {{hash, match_tags}, :_, match_value},
        [{:==, match_tags, tags}],
        [match_value]
      }
    ]

    case :ets.select(tid, spec) do
      [value] -> value
      _ -> nil
    end
  end

  def get_metric(tid, %Metrics.Distribution{event_name: event_name} = metric, tags) do
    hash = :erlang.phash2(metric)
    match_value = :"$1"
    match_tags = :"$2"

    spec = [
      {
        {{hash, match_tags}, :_, match_value},
        [{:==, match_tags, tags}],
        [match_value]
      }
    ]

    case :ets.select(tid, spec) do
      [atomics] -> Storage.Atomics.values(atomics)
      _ -> nil
    end
  end

  # private
  defp group_metrics([], acc) do
    acc
  end

  defp group_metrics([metric | rest], acc) do
    acc2 = group_metric(metric, acc)
    group_metrics(rest, acc2)
  end

  defp group_metric({{_hash, tags}, %Metrics.Counter{} = metric, value}, acc) do
    update_in(acc, [Access.key(metric, %{}), Access.key(tags, 0)], &(&1 + value))
  end

  defp group_metric({{_hash, tags}, %Metrics.Sum{} = metric, value}, acc) do
    update_in(acc, [Access.key(metric, %{}), Access.key(tags, 0)], &(&1 + value))
  end

  defp group_metric({{_hash, tags}, %Metrics.LastValue{} = metric, value}, acc) do
    put_in(acc, [Access.key(metric, %{}), Access.key(tags)], value)
  end

  defp group_metric({{_hash, tags}, %Metrics.Distribution{} = metric, atomics}, acc) do
    put_in(acc, [Access.key(metric, %{}), Access.key(tags)], Storage.Atomics.values(atomics))
  end

  defp lookup_atomics(tid, {hash, tags}) do
    atomics = :"$1"
    match_tags = :"$2"

    match_spec = [
      {
        {{hash, match_tags}, :_, atomics},
        [{:==, match_tags, tags}],
        [atomics]
      }
    ]

    :ets.select(tid, match_spec)
  end

  defp make_key(hash, %Metrics.Counter{event_name: event_name} = metric, %{} = tags) do
    # {event_name, Metrics.Counter, tags, metric}
    {hash, tags}
  end

  defp make_key(hash, %Metrics.Sum{event_name: event_name} = metric, %{} = tags) do
    # {event_name, Metrics.Sum, tags, metric}
    {hash, tags}
  end

  defp make_key(hash, %Metrics.LastValue{event_name: event_name} = metric, %{} = tags) do
    # {event_name, Metrics.LastValue, tags, metric}
    {hash, tags}
  end

  defp make_key(hash, %Metrics.Distribution{event_name: event_name} = metric, %{} = tags) do
    # {event_name, Metrics.Distribution, tags, metric}
    {hash, tags}
  end

  defp sum(l, acc \\ 0)
  defp sum([], acc), do: acc
  defp sum([h | t], acc), do: sum(t, acc + h)
end
