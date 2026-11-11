defmodule Peep.Storage do
  @moduledoc """
  Behaviour for Peep storage backends. These functions are mainly called by Peep
  during normal functioning. Ordinary usage of Peep should not require calling
  any of these functions.

  An implementation of Peep.Storage must implement one of:

  * `c:insert_metric/5`
  * `c:insert_metrics/3`

  When Peep starts, it will see which of the above callbacks is exported, and
  :telemetry event handlers will call the exported function.

  Unless you have a good reason (e.g. your Peep.Storage implementation uses
  NIFs), prefer `c:insert_metric/5`. `c:insert_metrics/3` builds a list with one
  tuple per metric for each event, which only pays off when a call into the
  backend is expensive enough to be worth amortizing.
  """
  alias Telemetry.Metrics

  @typep persistent() :: Peep.Persistent.t()
  @typep ids_to_metrics() :: Peep.Persistent.ids_to_metrics()

  @doc """
  Creates a new term representing a Peep storage backend.
  """
  @callback new(term) :: term()

  @doc """
  Calculates the amount of memory used by a Peep storage backend.
  """
  @callback storage_size(term()) :: %{size: non_neg_integer(), memory: non_neg_integer()}

  @doc """
  Stores a single sample.

  Called once per metric of an event.
  """
  @callback insert_metric(
              storage :: term(),
              Peep.metric_id(),
              Metrics.t(),
              value :: number(),
              tags :: map()
            ) :: any()

  @doc """
  Stores every sample belonging to a single telemetry event.

  A sample's tags are `elem(tag_results, tag_idx)`.
  """
  @callback insert_metrics(
              storage :: term(),
              tag_results :: tuple(),
              [{Peep.metric_id(), Metrics.t(), number(), tag_idx :: non_neg_integer()}]
            ) :: any()

  @doc """
  Retrieves all stored metrics
  """
  @callback get_all_metrics(term(), persistent()) :: map()

  @doc """
  Removes metrics whose metadata contains a specific tag key and value.
  This is intended to improve situations where Peep emits metrics whose tags
  have high cardinality.
  """
  @callback prune_tags(term(), [%{Metrics.tag() => term()}]) :: :ok

  @doc """
  Called once when Peep starts to inform a backend about Peep's metrics.

  Each distribution carries `:peep_buckets`: unique `{upper_bound, label}`
  pairs sorted by upper bound (which is always a float).
  """
  @callback register_metrics(
              storage :: term(),
              ids_to_metrics :: ids_to_metrics()
            ) :: :ok

  @doc """
  Resolves storage to its per-scheduler form for the current scheduler.
  Called once per event to avoid redundant scheduler lookups across metrics.
  """
  @callback resolve(term()) :: term()

  @optional_callbacks insert_metric: 5, insert_metrics: 3, register_metrics: 2

  @doc false
  @spec insert_shape(module()) :: :batched | :per_metric
  def insert_shape(storage_mod) do
    cond do
      not Code.ensure_loaded?(storage_mod) ->
        raise ArgumentError, "storage module #{inspect(storage_mod)} could not be loaded"

      function_exported?(storage_mod, :insert_metrics, 3) ->
        :batched

      function_exported?(storage_mod, :insert_metric, 5) ->
        :per_metric

      true ->
        raise ArgumentError,
              "storage module #{inspect(storage_mod)} exports neither " <>
                "insert_metric/5 nor insert_metrics/3"
    end
  end

  @doc false
  def float_sum!(storage_mod, %Metrics.Sum{name: name}, value) do
    raise ArgumentError,
          "#{inspect(storage_mod)} can't add the float #{value} to the sum #{inspect(name)}: " <>
            "it adds only integers to a sum. To report a sum in another unit, set " <>
            ":peep_export_conversion_factor in its :reporter_options instead of converting with :unit"
  end

  @doc false
  @spec registers_metrics?(module()) :: boolean()
  def registers_metrics?(storage_mod) do
    Code.ensure_loaded?(storage_mod) and function_exported?(storage_mod, :register_metrics, 2)
  end
end
