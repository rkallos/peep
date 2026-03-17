defmodule Peep.EventHandler do
  @moduledoc false

  @compile {:inline, keep?: 3, fetch_measurement: 3}

  import Peep.Persistent, only: [persistent: 1]

  def attach(name) do
    persistent(
      events_to_metrics: metrics_by_event,
      storage: storage
    ) = Peep.Persistent.fetch(name)

    pairs =
      for {event_name, metrics} <- metrics_by_event do
        event_key = :erlang.unique_integer([:positive, :monotonic])
        :persistent_term.put(event_key, {storage, metrics})
        handler_id = handler_id(event_name, name)

        :ok =
          :telemetry.attach(
            handler_id,
            event_name,
            &__MODULE__.handle_event/4,
            event_key
          )

        {handler_id, event_key}
      end

    Enum.unzip(pairs)
  end

  def detach(handler_ids, event_keys) do
    for id <- handler_ids, do: :telemetry.detach(id)
    for key <- event_keys, do: :persistent_term.erase(key)
    :ok
  end

  defp handler_id(event_name, peep_name) do
    {__MODULE__, peep_name, event_name}
  end

  def precompute_metrics(metrics, {storage_mod, _}) do
    Enum.map(metrics, fn {metric, id} ->
      %{
        measurement: measurement,
        tag_values: tag_values,
        tags: tags,
        keep: keep
      } = metric

      tag_fn = compile_tag_fn(tag_values, tags)
      keep_val = if is_nil(keep), do: :no_keep, else: keep

      insert_fn = fn data, value, tags ->
        storage_mod.insert_metric(data, id, metric, value, tags)
      end

      {metric_type(metric), insert_fn, keep_val, measurement, tag_fn}
    end)
  end

  defp metric_type(%Telemetry.Metrics.Counter{}), do: :counter
  defp metric_type(_), do: :other

  defp compile_tag_fn(_tag_values, []), do: fn _metadata -> %{} end
  defp compile_tag_fn(_tag_values, tags) when is_function(tags, 1), do: tags
  defp compile_tag_fn(tag_values, keys), do: fn metadata -> Map.take(tag_values.(metadata), keys) end

  def handle_event(_event, measurements, metadata, event_key) do
    {{storage_mod, storage}, metrics} = :persistent_term.get(event_key)
    resolved = storage_mod.resolve(storage)
    store_metrics(metrics, measurements, metadata, resolved)
  end

  defp store_metrics([], _measurements, _metadata, _data), do: :ok

  defp store_metrics(
         [{:counter, insert_fn, :no_keep, _measurement, tag_fn} | rest],
         measurements,
         metadata,
         data
       ) do
    insert_fn.(data, 1, tag_fn.(metadata))
    store_metrics(rest, measurements, metadata, data)
  end

  defp store_metrics(
         [{_type, insert_fn, :no_keep, measurement, tag_fn} | rest],
         measurements,
         metadata,
         data
       ) do
    case fetch_measurement(measurement, measurements, metadata) do
      value when is_number(value) ->
        insert_fn.(data, value, tag_fn.(metadata))

      _ ->
        nil
    end

    store_metrics(rest, measurements, metadata, data)
  end

  defp store_metrics(
         [{:counter, insert_fn, keep, _measurement, tag_fn} | rest],
         measurements,
         metadata,
         data
       ) do
    if keep?(keep, metadata, nil) do
      insert_fn.(data, 1, tag_fn.(metadata))
    end

    store_metrics(rest, measurements, metadata, data)
  end

  defp store_metrics(
         [{_type, insert_fn, keep, measurement, tag_fn} | rest],
         measurements,
         metadata,
         data
       ) do
    if keep?(keep, metadata, measurement) do
      # credo:disable-for-next-line Credo.Check.Refactor.Nesting
      case fetch_measurement(measurement, measurements, metadata) do
        value when is_number(value) ->
          insert_fn.(data, value, tag_fn.(metadata))

        _ ->
          nil
      end
    end

    store_metrics(rest, measurements, metadata, data)
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
