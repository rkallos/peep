defmodule Peep.EventHandler do
  @moduledoc false

  @compile {:inline, keep?: 3, meta: 3, fetch_measurement: 3}

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

  def handle_event(event, measurements, metadata, name) do
    persistent(
      events_to_metrics: %{^event => metrics},
      storage: {storage_mod, storage}
    ) = Peep.Persistent.fetch(name)

    store_metrics(metrics, measurements, metadata, storage_mod, storage)
  end

  defp store_metrics([], _measurements, _metadata, _mod, _data), do: :ok

  defp store_metrics([{metric, id} | rest], measurements, metadata, mod, data) do
    %{
      measurement: measurement,
      tag_values: tag_values,
      tags: tags,
      keep: keep
    } = metric

    if keep?(keep, metadata, measurement) do
      # credo:disable-for-next-line Credo.Check.Refactor.Nesting
      case fetch_measurement(measurement, measurements, metadata) do
        value when is_number(value) ->
          mod.insert_metric(
            data,
            id,
            metric,
            value,
            meta(metadata, tag_values, tags)
          )

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

  # When selected list is empty, just return empty map
  defp meta(_tags, _map, []), do: %{}
  defp meta(meta, _map, tags) when is_function(tags, 1), do: tags.(meta)
  defp meta(tags, map, keys), do: Map.take(map.(tags), keys)

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
