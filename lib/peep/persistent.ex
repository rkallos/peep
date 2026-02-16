defmodule Peep.Persistent do
  @moduledoc false

  require Record

  Record.defrecord(:persistent, [
    :name,
    :storage,
    events_to_metrics: %{},
    ids_to_metrics: %{},
    metrics_to_ids: %{}
  ])

  @compile {:inline, key: 1, fetch: 1}

  @type name() :: atom()

  @typep storage() :: {module, term()}
  @typep events_to_metrics() :: %{
           :telemetry.event_name() => [{Telemetry.Metrics.t(), non_neg_integer()}]
         }
  @typep metrics_to_ids() :: %{Telemetry.Metrics.t() => Peep.metric_id()}

  @type ids_to_metrics() :: %{Peep.metric_id() => Telemetry.Metrics.t()}
  @type t() ::
          record(:persistent,
            name: name(),
            storage: storage(),
            events_to_metrics: events_to_metrics(),
            ids_to_metrics: ids_to_metrics(),
            metrics_to_ids: metrics_to_ids()
          )

  @spec new(Peep.Options.t()) :: t()
  def new(%Peep.Options{} = options) do
    %Peep.Options{name: name, storage: storage_impl, metrics: metrics} = options

    storage =
      case storage_impl do
        :default ->
          {Peep.Storage.ETS, Peep.Storage.ETS.new([])}

        :striped ->
          {Peep.Storage.Striped, Peep.Storage.Striped.new([])}

        {mod, opts} when is_atom(mod) ->
          {mod, mod.new(opts)}
      end

    %{
      events_to_metrics: events_to_metrics,
      ids_to_metrics: ids_to_metrics,
      metrics_to_ids: metrics_to_ids
    } = Peep.assign_metric_ids(metrics)

    persistent(
      name: name,
      storage: storage,
      events_to_metrics: events_to_metrics,
      ids_to_metrics: ids_to_metrics,
      metrics_to_ids: metrics_to_ids
    )
  end

  @spec store(t()) :: :ok
  def store(persistent() = term) do
    persistent(name: name) = term
    :persistent_term.put(key(name), term)
  end

  @spec fetch(name()) :: t() | nil
  def fetch(name) when is_atom(name) do
    :persistent_term.get(key(name), nil)
  end

  @spec erase(name()) :: :ok
  def erase(name) when is_atom(name) do
    :persistent_term.erase(name)
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

  defmacro fast_fetch(name) when is_atom(name) do
    quote do
      :persistent_term.get(unquote(key(name)), nil)
    end
  end

  defp key(name) when is_atom(name) do
    {Peep, name}
  end
end
