defmodule Peep.EventHandler do
  @moduledoc false

  @compile {:inline, keep?: 3, fetch_measurement: 3}

  import Peep.Persistent, only: [persistent: 1]

  require Peep.Handler.Config
  require Peep.Handler.Metric

  alias Peep.Handler.Config
  alias Peep.Handler.Metric

  def attach(
        persistent(
          name: name,
          events_to_metrics: metrics_by_event,
          storage: {storage_mod, storage}
        )
      ) do
    for {event_name, metrics} <- metrics_by_event do
      handler_id = handler_id(event_name, name)

      :ok =
        :telemetry.attach(
          handler_id,
          event_name,
          &__MODULE__.handle_event/4,
          Config.new(metrics, storage_mod, storage)
        )

      handler_id
    end
  end

  def detach(handler_ids) do
    for id <- handler_ids, do: :telemetry.detach(id)
    :ok
  end

  defp handler_id(event_name, peep_name) do
    {__MODULE__, peep_name, event_name}
  end

  def handle_event(
        _event,
        measurements,
        metadata,
        Config.handler_config(
          metrics: metrics,
          storage_mod: storage_mod,
          storage: storage,
          tag_fns: tag_fns
        )
      ) do
    resolved = storage_mod.resolve(storage)
    tag_results = compute_tags(tag_fns, metadata, tuple_size(tag_fns) - 1, [])
    store_metrics(metrics, measurements, metadata, resolved, tag_results)
  end

  defp compute_tags(_tag_fns, _metadata, -1, acc) do
    List.to_tuple(acc)
  end

  defp compute_tags(tag_fns, metadata, idx, acc) do
    compute_tags(tag_fns, metadata, idx - 1, [elem(tag_fns, idx).(metadata) | acc])
  end

  defp store_metrics([], _measurements, _metadata, _data, _tag_results), do: :ok

  # Order matters; literal :no_keep and :counter clauses must precede the catch-alls.
  clause_order = [
    %{keep?: false, counter?: true},
    %{keep?: false, counter?: false},
    %{keep?: true, counter?: true},
    %{keep?: true, counter?: false}
  ]

  # Dialyzer sees the `if true` and `case 1` the template leaves before the compiler folds them.
  @dialyzer {:no_match, store_metrics: 5}

  for %{keep?: keep?, counter?: counter?} <- clause_order do
    type = if counter?, do: :counter, else: quote(do: _)
    keep = if keep?, do: quote(do: var!(keep)), else: :no_keep
    measurement = if counter?, do: quote(do: _), else: quote(do: var!(measurement))

    kept? =
      if keep?,
        do: quote(do: keep?(var!(keep), var!(metadata), var!(measurements))),
        else: true

    value =
      if counter?,
        do: 1,
        else: quote(do: fetch_measurement(var!(measurement), var!(measurements), var!(metadata)))

    defp store_metrics(
           [
             Metric.handler_metric(
               type: unquote(type),
               insert_fn: insert_fn,
               keep: unquote(keep),
               measurement: unquote(measurement),
               tag_idx: tag_idx
             )
             | rest
           ],
           measurements,
           metadata,
           data,
           tag_results
         ) do
      if unquote(kept?) do
        case unquote(value) do
          value when is_number(value) -> insert_fn.(data, value, elem(tag_results, tag_idx))
          _ -> nil
        end
      end

      store_metrics(rest, measurements, metadata, data, tag_results)
    end
  end

  defp keep?(keep, metadata, measurement) when is_function(keep, 2),
    do: keep.(metadata, measurement)

  defp keep?(keep, metadata, _measurement) when is_function(keep, 1), do: keep.(metadata)
  defp keep?(_keep, _metadata, _measurement), do: true

  defp fetch_measurement(measurement, measurements, metadata) do
    case measurement do
      nil ->
        nil

      fun when is_function(fun, 1) ->
        fun.(measurements)

      fun when is_function(fun, 2) ->
        fun.(measurements, metadata)

      key ->
        case measurements do
          %{^key => value} -> value
          _ -> 1
        end
    end
  end
end
