defmodule Peep.EventHandler do
  require Logger

  alias Peep.Storage

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
            global_tags: global_tags
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

        Storage.insert_metric(tid, metric, value, tags)
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
end
