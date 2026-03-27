defmodule Peep.Handler.Metric do
  @moduledoc """
  A pre-compiled representation of a single metric within a telemetry handler.

  Each record captures everything needed to store a sample in the hot path:

    * `type` — `:counter` or `:other`. Counters are special-cased: they always
      store value `1` and skip measurement lookup entirely.

    * `insert_fn` — a closure over `storage_mod`, metric id, and the metric
      struct. Calling `insert_fn.(resolved_storage, value, tags)` writes
      directly to the storage backend, avoiding repeated map/struct lookups
      on every event.

    * `keep` — the keep filter, or `:no_keep` when absent. Splitting `:no_keep`
      from function-valued keeps lets `store_metrics` clause-match into four
      fast paths (counter/other × keep/no_keep).

    * `measurement` — the measurement key, or a 1-/2-arity function. Stored
      verbatim from the metric struct so `fetch_measurement` can extract the
      value from the measurements map without re-traversing the metric.

    * `tag_idx` — index into the pre-computed tag results tuple. Metrics that
      share the same `tags`/`tag_values` configuration share a single tag
      function (deduplicated during `Peep.Handler.Config.new/3`), and `tag_idx`
      points to the result of that shared function, avoiding redundant tag
      computation per event.
  """

  require Record

  Record.defrecord(:handler_metric, [:type, :insert_fn, :keep, :measurement, :tag_idx])

  @type t ::
          record(:handler_metric,
            type: :counter | :other,
            insert_fn: (term(), number(), map() -> any()),
            keep: :no_keep | (map() -> boolean()) | (map(), term() -> boolean()),
            measurement: atom() | (map() -> number()) | (map(), map() -> number()) | nil,
            tag_idx: non_neg_integer()
          )

  @spec new(Telemetry.Metrics.t(), Peep.metric_id(), module(), non_neg_integer()) :: t()
  def new(metric, id, storage_mod, tag_idx) do
    insert_fn = fn data, value, tags ->
      storage_mod.insert_metric(data, id, metric, value, tags)
    end

    handler_metric(
      type: metric_type(metric),
      insert_fn: insert_fn,
      keep: keep_value(metric),
      measurement: metric.measurement,
      tag_idx: tag_idx
    )
  end

  defp metric_type(%Telemetry.Metrics.Counter{}), do: :counter
  defp metric_type(_), do: :other

  defp keep_value(%{keep: nil}), do: :no_keep
  defp keep_value(%{keep: keep}), do: keep
end
