defmodule Peep.EventHandler do
  require Logger

  alias Telemetry.Metrics

  @alpha 0.10
  @gamma (1 + @alpha) / (1 - @alpha)
  @denominator :math.log(@gamma)

  def attach(metrics, tid) do
    metrics_by_event = Enum.group_by(metrics, & &1.event_name)

    for {event_name, metrics} <- metrics_by_event do
      handler_id = handler_id(event_name, tid)

      :ok =
        :telemetry.attach(
          handler_id,
          event_name,
          &__MODULE__.handle_event/4,
          %{
            tid: tid,
            metrics: metrics,
            # TODO: Add global tags
            global_tags: []
          }
        )

      handler_id
    end
  end

  def handle_event(_event, measurements, metadata, %{
        tid: tid,
        metrics: metrics,
        global_tags: global_tags
      }) do
    for metric <- metrics do
      if value = keep?(metric, metadata) && fetch_measurement(metric, measurements, metadata) do
        tag_values =
          global_tags
          |> Map.new()
          |> Map.merge(metric.tag_values.(metadata))

        tags = Enum.map(metric.tags, &{&1, Map.get(tag_values, &1, "")})

        # Logger.info(
        #   event: :pre_insert,
        #   metric: metric,
        #   measurements: measurements,
        #   metadata: metadata,
        #   value: value
        # )

        insert_metric(tid, metric, value, tags)
      end
    end
  end

  defp handler_id(event_name, tid) do
    {__MODULE__, tid, event_name}
  end

  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(%{keep: keep}, metadata), do: keep.(metadata)

  defp fetch_measurement(metric, measurements, metadata) do
    case metric.measurement do
      nil ->
        nil

      fun when is_function(fun, 1) ->
        fun.(measurements)

      fun when is_function(fun, 2) ->
        fun.(measurements, metadata)

      key ->
        measurements[key] || 1
    end
  end

  defp insert_metric(tid, %Metrics.Counter{name: name}, value, tags) do
    key = {:counter, name, tags}
    :ets.update_counter(tid, key, {2, value}, {key, 0})
  end

  defp insert_metric(tid, %Metrics.LastValue{name: name}, value, tags) do
    key = {:last_value, name, tags}
    :ets.insert(tid, {key, value})
  end

  defp insert_metric(tid, %Metrics.Distribution{name: name}, value, tags) do
    bucket = trunc(:math.log(value) / @denominator)
    key = {:distribution, name, tags, bucket}
    :ets.update_counter(tid, key, {2, 1}, {key, 0})
  end

  defp insert_metric(_tid, metric, value, tags) do
    :ok
  end
end
