defmodule Peep.Storage do
  @moduledoc """
  Behaviour for Peep storage backends. These functions are mainly called by Peep
  during normal functioning. Ordinary usage of Peep should not require calling
  any of these functions.
  """
  alias Telemetry.Metrics

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

  Called once per metric of an event. This is the shape a backend gets unless it
  exports `c:insert_metrics/3`.

  A backend must export this or `c:insert_metrics/3`. Both are optional
  callbacks because a behaviour cannot say "exactly one of these"; exporting
  neither raises when the reporter starts.
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

  A backend that exports this function receives one call per event and never has
  `c:insert_metric/5` called; a backend that does not export it receives one
  `c:insert_metric/5` call per metric. Which one a backend gets is decided once,
  when its handler is attached, so neither shape costs the other anything per
  event.

  The choice exists because batching trades BEAM heap allocation for fewer
  calls: assembling the batch allocates a work item per metric. That is worth it
  for a NIF backend, where a call costs tens of nanoseconds in argument
  marshalling and resource decoding, and a measurable loss for the ETS backends,
  where a call is cheap and the extra garbage is not. Neither built-in backend
  exports it.

  Batch items are `{id, metric, value, tag_idx}` tuples. `tag_idx` is an index
  into `tag_results`, so a backend reads a sample's tags with
  `elem(tag_results, tag_idx)`.

  Tags are passed by index instead of inline because several metrics attached
  to one event usually share a single tags map. That is exactly why
  `Peep.Handler.Config` deduplicates tag functions, and it lets a backend hash
  or look up each distinct tags map once per event rather than once per metric.

  Batch order is unspecified. A metric appears at most once per event, so no
  two items can collide on the same id and tags, including for
  `Telemetry.Metrics.LastValue`.
  """
  @callback insert_metrics(
              storage :: term(),
              tag_results :: tuple(),
              [{Peep.metric_id(), Metrics.t(), number(), non_neg_integer()}]
            ) :: any()

  @doc """
  Retrieves all stored metrics
  """
  @callback get_all_metrics(term(), Peep.Persistent.t()) :: map()

  @doc """
  Removes metrics whose metadata contains a specific tag key and value.
  This is intended to improve situations where Peep emits metrics whose tags
  have high cardinality.
  """
  @callback prune_tags(term(), [%{Metrics.tag() => term()}]) :: :ok

  @doc """
  Called once when Peep starts, so a backend can get what it needs to know
  about Peep's metrics up front instead of calling into Peep while handling
  telemetry events.

  Each distribution carries `:peep_buckets`: `{upper_bound, label}` pairs sorted
  by bound, with no repeated bound or label. Bounds are exclusive floats; a
  sample at or above the last one belongs in the `:infinity` bucket.
  """
  @callback register_metrics(
              storage :: term(),
              ids_to_metrics :: Peep.Persistent.ids_to_metrics()
            ) :: :ok

  @doc """
  Resolves storage to its per-scheduler form for the current scheduler.
  Called once per event to avoid redundant scheduler lookups across metrics.
  """
  @callback resolve(term()) :: term()

  @optional_callbacks insert_metric: 5, insert_metrics: 3, register_metrics: 2

  @doc """
  Reports whether a storage module is called once per event (`:batched`) or once
  per metric (`:per_metric`).

  Decided once, when the handler attaches, from which optional insert callback
  the module exports. Raises if the module cannot be loaded or exports neither.
  """
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
  @spec registers_metrics?(module()) :: boolean()
  def registers_metrics?(storage_mod) do
    Code.ensure_loaded?(storage_mod) and function_exported?(storage_mod, :register_metrics, 2)
  end
end
