defmodule Peep.Persistent do
  @moduledoc false

  alias Peep.Storage

  require Record

  Record.defrecord(:persistent, [
    :name,
    :storage,
    events_to_metrics: %{},
    ids_to_metrics: {},
    global_tags: %{}
  ])

  @compile {:inline, key: 1, fetch: 1}

  @type name() :: atom()

  @typep storage() :: {module, term()}
  @typep events_to_metrics() :: %{
           :telemetry.event_name() => [{Telemetry.Metrics.t(), non_neg_integer()}]
         }
  @type ids_to_metrics() :: tuple()
  @type t() ::
          record(:persistent,
            name: name(),
            storage: storage(),
            events_to_metrics: events_to_metrics(),
            ids_to_metrics: ids_to_metrics(),
            global_tags: map()
          )

  @spec new(Peep.Options.t()) :: t()
  def new(%Peep.Options{} = options) do
    %Peep.Options{
      name: name,
      storage: storage_impl,
      metrics: metrics,
      global_tags: global_tags
    } = options

    storage =
      case storage_impl do
        :default ->
          {Storage.ETS, Storage.ETS.new([])}

        :striped ->
          {Storage.Striped, Storage.Striped.new([])}

        {mod, opts} when is_atom(mod) ->
          {mod, mod.new(opts)}
      end

    {events_to_metrics, ids_to_metrics} = assign_metric_ids(metrics)

    persistent(
      name: name,
      storage: storage,
      events_to_metrics: events_to_metrics,
      ids_to_metrics: ids_to_metrics,
      global_tags: global_tags
    )
  end

  @spec store(t()) :: :ok
  def store(persistent(name: name, storage: {mod, state}, ids_to_metrics: i2m) = term) do
    if Peep.Storage.registers_metrics?(mod) do
      mod.register_metrics(state, with_buckets(i2m))
    end

    :persistent_term.put(key(name), term)
    :ok
  end

  @spec fetch(name()) :: t() | nil
  def fetch(name) when is_atom(name) do
    :persistent_term.get(key(name), nil)
  end

  @spec erase(name()) :: :ok
  def erase(name) when is_atom(name) do
    :persistent_term.erase(key(name))
    :ok
  end

  @spec storage(name()) :: {module(), term()} | nil
  def storage(name) when is_atom(name) do
    case fetch(name) do
      persistent(storage: s) ->
        s

      _ ->
        nil
    end
  end

  @spec ids_to_metrics(t()) :: ids_to_metrics()
  def ids_to_metrics(persistent(ids_to_metrics: itm)), do: itm

  defp assign_metric_ids(metrics) do
    indexed =
      metrics
      |> Enum.filter(&Peep.allow_metric?/1)
      |> Enum.uniq()
      |> Enum.with_index()

    events_to_metrics =
      Enum.group_by(indexed, fn {metric, _id} -> metric.event_name end)

    ids_to_metrics =
      indexed
      |> Enum.map(fn {metric, _id} -> metric end)
      |> List.to_tuple()

    {events_to_metrics, ids_to_metrics}
  end

  defp with_buckets(ids_to_metrics) do
    ids_to_metrics
    |> Tuple.to_list()
    |> Enum.map(fn
      %Telemetry.Metrics.Distribution{} = d -> Map.put(d, :peep_buckets, buckets(d))
      metric -> metric
    end)
    |> List.to_tuple()
  end

  # Of buckets sharing a label, the one with the highest bound is kept.
  defp buckets(distribution) do
    {mod, config} = Peep.Buckets.config(distribution)

    mod.boundaries(config)
    |> Enum.with_index(fn bound, idx -> {bound * 1.0, mod.upper_bound(idx, config)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.dedup_by(&elem(&1, 0))
    |> Enum.reverse()
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.reverse()
  end

  defp key(name) when is_atom(name) do
    {Peep, name}
  end
end
