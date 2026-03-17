defmodule Peep.EventHandler do
  @moduledoc false

  @compile {:inline, keep?: 3, fetch_measurement: 3}

  import Peep.Persistent, only: [persistent: 1]

  def attach(name) do
    persistent(events_to_metrics: metrics_by_event) = Peep.Persistent.fetch(name)

    for {event_name, _metrics} <- metrics_by_event do
      handler_id = handler_id(event_name, name)

      :ok =
        :telemetry.attach(
          handler_id,
          event_name,
          &__MODULE__.handle_event/4,
          name
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

  def precompute_metrics(metrics) do
    Enum.map(metrics, fn {metric, id} ->
      %{
        measurement: measurement,
        tag_values: tag_values,
        tags: tags,
        keep: keep
      } = metric

      tag_fn = compile_tag_fn(tag_values, tags)
      {id, metric_type(metric), metric, keep, measurement, tag_fn}
    end)
  end

  defp metric_type(%Telemetry.Metrics.Counter{}), do: :counter
  defp metric_type(_), do: :other

  defp compile_tag_fn(_tag_values, []), do: fn _metadata -> %{} end
  defp compile_tag_fn(_tag_values, tags) when is_function(tags, 1), do: tags
  defp compile_tag_fn(tag_values, keys), do: fn metadata -> Map.take(tag_values.(metadata), keys) end

  def handle_event(event, measurements, metadata, name) do
    persistent(
      events_to_metrics: %{^event => metrics},
      storage: {storage_mod, storage}
    ) = Peep.Persistent.fetch(name)

    store_metrics(metrics, measurements, metadata, storage_mod, storage)
  end

  defp store_metrics([], _measurements, _metadata, _mod, _data), do: :ok

  defp store_metrics(
         [{id, :counter, metric, keep, _measurement, tag_fn} | rest],
         measurements,
         metadata,
         mod,
         data
       ) do
    if keep?(keep, metadata, nil) do
      mod.insert_metric(data, id, metric, 1, tag_fn.(metadata))
    end

    store_metrics(rest, measurements, metadata, mod, data)
  end

  defp store_metrics(
         [{id, _type, metric, keep, measurement, tag_fn} | rest],
         measurements,
         metadata,
         mod,
         data
       ) do
    if keep?(keep, metadata, measurement) do
      # credo:disable-for-next-line Credo.Check.Refactor.Nesting
      case fetch_measurement(measurement, measurements, metadata) do
        value when is_number(value) ->
          mod.insert_metric(data, id, metric, value, tag_fn.(metadata))

        _ ->
          nil
      end
    end

    store_metrics(rest, measurements, metadata, mod, data)
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
