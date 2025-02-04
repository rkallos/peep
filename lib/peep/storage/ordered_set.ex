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

  defdelegate storage_size(tid), to: ETS

  @impl true
  def insert_metric(tid, %Metrics.Counter{} = metric, _value, %{} = tags) do
    key = make_key(metric, tags)
    :ets.update_counter(tid, key, {2, 1}, {key, 0})
  end

  def insert_metric(tid, %Metrics.Sum{} = metric, value, %{} = tags) do
    key = make_key(metric, tags)
    :ets.update_counter(tid, key, {2, value}, {key, 0})
  end

  def insert_metric(tid, %Metrics.LastValue{} = metric, value, %{} = tags)
      when is_number(value) do
    key = make_key(metric, tags)
    :ets.update_element(tid, key, {2, value}, {key, value})
  end

  def insert_metric(_tid, %Metrics.LastValue{} = _metric, _value, _tags) do
    raise ArgumentError
  end

  def insert_metric(tid, %Metrics.Distribution{} = metric, value, %{} = tags) do
    key = make_key(metric, tags)

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

          case :ets.insert_new(tid, {key, new_atomics}) do
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
    match_value = :"$1"
    match_tags = :"$2"
    spec = [
      {
        {{event_name, Metrics.Counter, match_tags}, match_value},
        [{:==, match_tags, tags}],
        [match_value]
      }
    ]
    sum(:ets.select(tid, spec))
  end

  def get_metric(tid, %Metrics.Sum{event_name: event_name} = metric, tags) do
    match_value = :"$1"
    match_tags = :"$2"
    spec = [
      {
        {{event_name, Metrics.Sum, match_tags}, match_value},
        [{:==, match_tags, tags}],
        [match_value]
      }
    ]
    sum(:ets.select(tid, spec))
  end

  def get_metric(tid, %Metrics.LastValue{event_name: event_name} = metric, tags) do
    match_value = :"$1"
    match_tags = :"$2"
    spec = [
      {
        {{event_name, Metrics.LastValue, match_tags}, match_value},
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
    match_value = :"$1"
    match_tags = :"$2"
    spec = [
      {
        {{event_name, Metrics.Distribution, match_tags}, match_value},
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

  defp group_metric({{_event_name, _, %Metrics.Counter{} = metric, tags}, value}, acc) do
    update_in(acc, [Access.key(metric, %{}), Access.key(tags, 0)], &(&1 + value))
  end

  defp group_metric({{_event_name, _, %Metrics.Sum{} = metric, tags}, value}, acc) do
    update_in(acc, [Access.key(metric, %{}), Access.key(tags, 0)], &(&1 + value))
  end

  defp group_metric({{_event_name, _, %Metrics.LastValue{} = metric, tags}, value}, acc) do
    put_in(acc, [Access.key(metric, %{}), Access.key(tags)], value)
  end

  defp group_metric({{_event_name, _, %Metrics.Distribution{} = metric, tags}, atomics}, acc) do
    put_in(acc, [Access.key(metric, %{}), Access.key(tags)], Storage.Atomics.values(atomics))
  end

  defp lookup_atomics(tid, {event_name, Metrics.Distribution, metric, tags} = key) do
    atomics = :"$1"

    match_spec = [
      {
        {{event_name, Metrics.Distribution, metric, :"$2"}, atomics},
        [{:==, :"$2", tags}],
        [atomics]
      }
    ]

    :ets.select(tid, match_spec)
  end

  defp make_key(%Metrics.Counter{event_name: event_name} = metric, %{} = tags) do
    {event_name, Metrics.Counter, metric, tags}
  end

  defp make_key(%Metrics.Sum{event_name: event_name} = metric, %{} = tags) do
    {event_name, Metrics.Sum, metric, tags}
  end

  defp make_key(%Metrics.LastValue{event_name: event_name} = metric, %{} = tags) do
    {event_name, Metrics.LastValue, metric, tags}
  end

  defp make_key(%Metrics.Distribution{event_name: event_name} = metric, %{} = tags) do
    {event_name, Metrics.Distribution, metric, tags}
  end

  defp sum(l, acc \\ 0)
  defp sum([], acc), do: acc
  defp sum([h | t]), do: sum(t, acc + h)
end
