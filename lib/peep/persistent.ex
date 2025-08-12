defmodule Peep.Persistent do
  @moduledoc false
  defstruct [:name, :storage, :events_to_metrics, :ids_to_metrics, :metrics_to_ids]

  @compile {:inline, key: 1, fetch: 1}

  @type name() :: atom()

  @typep storage_default() :: {Peep.Storage.ETS, :ets.tid()}
  @typep storage_striped() :: {Peep.Storage.Striped, %{pos_integer() => :ets.tid()}}
  @typep storage() :: storage_default() | storage_striped()
  @typep events_to_metrics() :: %{
           :telemetry.event_name() => [{Telemetry.Metrics.t(), non_neg_integer()}]
         }
  @typep ids_to_metrics :: %{Peep.metric_id() => Telemetry.Metrics.t()}
  @typep metrics_to_ids :: %{Telemetry.Metrics.t() => Peep.metric_id()}

  @type t() :: %__MODULE__{
          name: name(),
          storage: storage(),
          events_to_metrics: events_to_metrics(),
          ids_to_metrics: ids_to_metrics(),
          metrics_to_ids: metrics_to_ids()
        }

  @spec new(Peep.Options.t()) :: t()
  def new(%Peep.Options{} = options) do
    %Peep.Options{name: name, storage: storage_impl, metrics: metrics} = options

    storage =
      case storage_impl do
        :default ->
          {Peep.Storage.ETS, Peep.Storage.ETS.new()}

        :striped ->
          {Peep.Storage.Striped, Peep.Storage.Striped.new()}
      end

    %{
      events_to_metrics: events_to_metrics,
      ids_to_metrics: ids_to_metrics,
      metrics_to_ids: metrics_to_ids
    } = Peep.assign_metric_ids(metrics)

    %__MODULE__{
      name: name,
      storage: storage,
      events_to_metrics: events_to_metrics,
      ids_to_metrics: ids_to_metrics,
      metrics_to_ids: metrics_to_ids
    }
  end

  @spec store(t()) :: :ok
  def store(%__MODULE__{} = term) do
    %__MODULE__{name: name} = term
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
      %__MODULE__{storage: s} ->
        s

      _ ->
        nil
    end
  end

  defmacro fast_fetch(name) when is_atom(name) do
    quote do
      :persistent_term.get(unquote(key(name)), nil)
    end
  end

  defp key(name) when is_atom(name) do
    {Peep, name}
  end
end
