defmodule Peep.EventHandler do
  @moduledoc false

  @compile {:inline, keep?: 3, fetch_measurement: 3}

  import Peep.Persistent, only: [persistent: 1]

  def attach(name) do
    persistent(
      events_to_metrics: metrics_by_event,
      storage: {storage_mod, storage}
    ) = Peep.Persistent.fetch(name)

    for {event_name, metrics} <- metrics_by_event do
      handler_id = handler_id(event_name, name)

      {tag_fns, metrics_with_tag_fn_idx} = deduplicate_tag_fns(metrics)

      metrics_rows =
        Enum.map(metrics_with_tag_fn_idx, fn {metric, id, tag_idx} ->
          %{measurement: measurement, keep: keep} = metric

          keep_val = if is_nil(keep), do: :no_keep, else: keep

          insert_fn = fn data, value, tags ->
            storage_mod.insert_metric(data, id, metric, value, tags)
          end

          {metric_type(metric), insert_fn, keep_val, measurement, tag_idx}
        end)

      :ok =
        :telemetry.attach(
          handler_id,
          event_name,
          &__MODULE__.handle_event/4,
          {metrics_rows, storage_mod, storage, tag_fns}
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
        {metrics_rows, storage_mod, storage, tag_fns}
      ) do
    tag_results = compute_tags(tag_fns, metadata, tuple_size(tag_fns), 0, [])
    store_metrics(metrics_rows, measurements, metadata, storage_mod, storage, tag_results)
  end

  defp compute_tags(_tag_fns, _metadata, size, size, acc) do
    acc |> :lists.reverse() |> List.to_tuple()
  end

  defp compute_tags(tag_fns, metadata, size, idx, acc) do
    compute_tags(tag_fns, metadata, size, idx + 1, [elem(tag_fns, idx).(metadata) | acc])
  end

  defp store_metrics([], _measurements, _metadata, _mod, _data, _tag_results), do: :ok

  defp store_metrics(
         [{:counter, insert_fn, :no_keep, _measurement, tag_idx} | rest],
         measurements,
         metadata,
         mod,
         data,
         tag_results
       ) do
    insert_fn.(data, 1, elem(tag_results, tag_idx))
    store_metrics(rest, measurements, metadata, mod, data, tag_results)
  end

  defp store_metrics(
         [{_type, insert_fn, :no_keep, measurement, tag_idx} | rest],
         measurements,
         metadata,
         mod,
         data,
         tag_results
       ) do
    case fetch_measurement(measurement, measurements, metadata) do
      value when is_number(value) ->
        insert_fn.(data, value, elem(tag_results, tag_idx))

      _ ->
        nil
    end

    store_metrics(rest, measurements, metadata, mod, data, tag_results)
  end

  defp store_metrics(
         [{:counter, insert_fn, keep, _measurement, tag_idx} | rest],
         measurements,
         metadata,
         mod,
         data,
         tag_results
       ) do
    if keep?(keep, metadata, nil) do
      insert_fn.(data, 1, elem(tag_results, tag_idx))
    end

    store_metrics(rest, measurements, metadata, mod, data, tag_results)
  end

  defp store_metrics(
         [{_type, insert_fn, keep, measurement, tag_idx} | rest],
         measurements,
         metadata,
         mod,
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

    store_metrics(rest, measurements, metadata, mod, data, tag_results)
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

  defp deduplicate_tag_fns(metrics) do
    {unique_metrics_tags, _} =
      Enum.reduce(metrics, {%{}, 0}, fn {metric, _id}, {map, next_idx} ->
        key = tag_fn_key(metric)

        case map do
          %{^key => _} -> {map, next_idx}
          _ -> {Map.put(map, key, next_idx), next_idx + 1}
        end
      end)

    tag_fns =
      unique_metrics_tags
      |> Enum.sort_by(fn {_key, idx} -> idx end)
      |> Enum.map(fn {{tag_values, tags}, _idx} -> compile_tag_fn(tag_values, tags) end)
      |> List.to_tuple()

    metrics_with_tag_fn_idx =
      Enum.map(metrics, fn {metric, id} ->
        key = tag_fn_key(metric)
        {metric, id, Map.fetch!(unique_metrics_tags, key)}
      end)

    {tag_fns, metrics_with_tag_fn_idx}
  end

  defp tag_fn_key(metric), do: {metric.tag_values, metric.tags}

  defp compile_tag_fn(_tag_values, []), do: fn _metadata -> %{} end
  defp compile_tag_fn(_tag_values, tags) when is_function(tags, 1), do: tags

  defp compile_tag_fn(tag_values, keys) do
    fn metadata -> Map.take(tag_values.(metadata), keys) end
  end

  defp metric_type(%Telemetry.Metrics.Counter{}), do: :counter
  defp metric_type(_), do: :other
end
