defmodule Peep.Handler.Config do
  @moduledoc """
  The configuration attached to a telemetry handler via `:telemetry.attach/4`.

  Built once per event during `Peep.EventHandler.attach/1`, compiling raw
  Telemetry.Metrics definitions into an optimized form:

    * `metrics` — a list of `Peep.Handler.Metric` records, one per metric
      definition attached to this event.

    * `storage_mod` — the `Peep.Storage` implementation module. Passed to Stored
      here so `Peep.EventHandler.handle_event/4` can call
      `storage_mod.resolve/1` once per event rather than once per metric.

    * `storage` — the storage state term (e.g. an ETS table id). Passed to
      `storage_mod.resolve/1` to get the resolved handle for the current
      scheduler.

    * `tag_fns` — a tuple of tag-computing functions, deduplicated across
      metrics that share the same `tags`/`tag_values` configuration. Evaluated
      once per event; each metric accesses its result in O(1) by `tag_idx`.
  """

  require Record

  alias Peep.Handler.Metric

  Record.defrecord(:handler_config, [:metrics, :storage_mod, :storage, :tag_fns])

  @type t ::
          record(:handler_config,
            metrics: [Metric.t()],
            storage_mod: module(),
            storage: term(),
            tag_fns: tuple()
          )

  @doc """
  Compiles a list of `{metric, id}` pairs into a handler config record.

  Metrics that share the same `tags`/`tag_values` configuration are assigned
  the same `tag_idx`, so their tag function is evaluated only once per event.
  """
  @spec new([{Telemetry.Metrics.t(), Peep.metric_id()}], module(), term()) :: t()
  def new(metrics, storage_mod, storage) do
    {tag_fn_indices, _} =
      Enum.reduce(metrics, {%{}, 0}, fn {metric, _id}, {map, next_idx} ->
        key = tag_fn_key(metric)

        case map do
          %{^key => _} -> {map, next_idx}
          _ -> {Map.put(map, key, next_idx), next_idx + 1}
        end
      end)

    tag_fns =
      tag_fn_indices
      |> Enum.sort_by(fn {_key, idx} -> idx end)
      |> Enum.map(fn {{tag_values, tags}, _idx} -> compile_tag_fn(tag_values, tags) end)
      |> List.to_tuple()

    handler_metrics =
      Enum.map(metrics, fn {metric, id} ->
        tag_idx = Map.fetch!(tag_fn_indices, tag_fn_key(metric))
        Metric.new(metric, id, storage_mod, tag_idx)
      end)

    handler_config(
      metrics: handler_metrics,
      storage_mod: storage_mod,
      storage: storage,
      tag_fns: tag_fns
    )
  end

  defp tag_fn_key(metric), do: {metric.tag_values, metric.tags}

  defp compile_tag_fn(_tag_values, []), do: fn _metadata -> %{} end
  defp compile_tag_fn(_tag_values, tags) when is_function(tags, 1), do: tags

  defp compile_tag_fn(tag_values, keys) do
    fn metadata -> Map.take(tag_values.(metadata), keys) end
  end
end
