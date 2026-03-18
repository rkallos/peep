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
    {tag_map, _} =
      Enum.reduce(metrics, {%{}, 0}, fn {metric, _id}, {map, next_idx} ->
        key = {metric.tag_values, metric.tags}

        case map do
          %{^key => _} -> {map, next_idx}
          _ -> {Map.put(map, key, next_idx), next_idx + 1}
        end
      end)

    tag_fns =
      tag_map
      |> Enum.sort_by(fn {_key, idx} -> idx end)
      |> Enum.map(fn {{tag_values, tags}, _idx} -> compile_tag_fn(tag_values, tags) end)
      |> List.to_tuple()

    metrics_list =
      Enum.map(metrics, fn {metric, id} ->
        %{
          measurement: measurement,
          tag_values: tag_values,
          tags: tags,
          keep: keep
        } = metric

        tag_idx = Map.fetch!(tag_map, {tag_values, tags})
        keep_val = if is_nil(keep), do: :no_keep, else: keep

        insert_fn = fn data, value, tags ->
          storage_mod.insert_metric(data, id, metric, value, tags)
        end

        {metric_type(metric), insert_fn, keep_val, measurement, tag_idx}
      end)

    {tag_fns, metrics_list}
  end

  defp metric_type(%Telemetry.Metrics.Counter{}), do: :counter
  defp metric_type(_), do: :other

  defp compile_tag_fn(_tag_values, []), do: fn _metadata -> %{} end
  defp compile_tag_fn(_tag_values, tags) when is_function(tags, 1), do: tags
  defp compile_tag_fn(tag_values, keys), do: fn metadata -> Map.take(tag_values.(metadata), keys) end

  def handle_event(_event, measurements, metadata, event_key) do
    {{storage_mod, storage}, {tag_fns, metrics}} = :persistent_term.get(event_key)
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
         [{:counter, insert_fn, :no_keep, _measurement, tag_idx} | rest],
         measurements,
         metadata,
         data,
         tag_results
       ) do
    insert_fn.(data, 1, elem(tag_results, tag_idx))
    store_metrics(rest, measurements, metadata, data, tag_results)
  end

  defp store_metrics(
         [{_type, insert_fn, :no_keep, measurement, tag_idx} | rest],
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
         [{:counter, insert_fn, keep, _measurement, tag_idx} | rest],
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
         [{_type, insert_fn, keep, measurement, tag_idx} | rest],
         measurements,
         metadata,
         data,
         tag_results
       ) do
    if keep?(keep, metadata, measurement) do
      # credo:disable-for-next-line Credo.Check.Refactor.Nesting
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
