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
    tag_results = compute_tags(tag_fns, metadata, tuple_size(tag_fns), 0, [])
    store_metrics(metrics, measurements, metadata, resolved, tag_results)
  end

  defp compute_tags(_tag_fns, _metadata, size, size, acc) do
    acc |> :lists.reverse() |> List.to_tuple()
  end

  defp compute_tags(tag_fns, metadata, size, idx, acc) do
    compute_tags(tag_fns, metadata, size, idx + 1, [elem(tag_fns, idx).(metadata) | acc])
  end

  defp store_metrics([], _measurements, _metadata, _data, _tag_results), do: :ok

  defp store_metrics(
         [
           Metric.handler_metric(
             type: :counter,
             insert_fn: insert_fn,
             keep: :no_keep,
             tag_idx: tag_idx
           )
           | rest
         ],
         measurements,
         metadata,
         data,
         tag_results
       ) do
    insert_fn.(data, 1, elem(tag_results, tag_idx))
    store_metrics(rest, measurements, metadata, data, tag_results)
  end

  defp store_metrics(
         [
           Metric.handler_metric(
             insert_fn: insert_fn,
             keep: :no_keep,
             measurement: measurement,
             tag_idx: tag_idx
           )
           | rest
         ],
         measurements,
         metadata,
         data,
         tag_results
       ) do
    case fetch_measurement(measurement, measurements, metadata) do
      value when is_number(value) ->
        insert_fn.(data, value, elem(tag_results, tag_idx))

      _ ->
        nil
    end

    store_metrics(rest, measurements, metadata, data, tag_results)
  end

  defp store_metrics(
         [
           Metric.handler_metric(
             type: :counter,
             insert_fn: insert_fn,
             keep: keep,
             tag_idx: tag_idx
           )
           | rest
         ],
         measurements,
         metadata,
         data,
         tag_results
       ) do
    if keep?(keep, metadata, nil) do
      insert_fn.(data, 1, elem(tag_results, tag_idx))
    end

    store_metrics(rest, measurements, metadata, data, tag_results)
  end

  defp store_metrics(
         [
           Metric.handler_metric(
             insert_fn: insert_fn,
             keep: keep,
             measurement: measurement,
             tag_idx: tag_idx
           )
           | rest
         ],
         measurements,
         metadata,
         data,
         tag_results
       ) do
    if keep?(keep, metadata, nil) do
      case fetch_measurement(measurement, measurements, metadata) do
        value when is_number(value) ->
          insert_fn.(data, value, elem(tag_results, tag_idx))

        _ ->
          nil
      end
    end

    store_metrics(rest, measurements, metadata, data, tag_results)
  end

  defp keep?(keep, metadata, measurement) when is_function(keep, 2),
    do: keep.(metadata, measurement)

  defp keep?(keep, metadata, _measurement) when is_function(keep, 1), do: keep.(metadata)
  defp keep?(_keep, _metadata, _measurement), do: true

  defp fetch_measurement(%Telemetry.Metrics.Counter{}, _measurements, _metadata) do
    1
  end

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
