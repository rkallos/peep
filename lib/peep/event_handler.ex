defmodule Peep.EventHandler do
  @moduledoc false
  require Logger

  @compile :inline

  alias Telemetry.Metrics.{Counter, Summary, Distribution}

  def attach(metrics, name, global_tags) do
    metrics_by_event = Enum.group_by(metrics, & &1.event_name)

    for {event_name, metrics} <- metrics_by_event do
      filtered_metrics = Enum.filter(metrics, &allow_metric?/1)
      handler_id = handler_id(event_name, name)

      :ok =
        :telemetry.attach(
          handler_id,
          event_name,
          &__MODULE__.handle_event/4,
          %{
            name: name,
            metrics: filtered_metrics,
            global_tags: global_tags
          }
        )

      handler_id
    end
  end

  def detach(handler_ids) do
    for id <- handler_ids, do: :telemetry.detach(id)
    :ok
  end

  def handle_event(_event, measurements, metadata, %{
        name: name,
        metrics: metrics,
        global_tags: global_tags
      }) do
    for metric <- metrics do
      %{
        measurement: measurement,
        tag_values: tag_values,
        tags: tags,
        keep: keep
      } = metric

      if value = keep?(keep, metadata) && fetch_measurement(measurement, measurements, metadata) do
        tag_values =
          global_tags
          |> Map.merge(tag_values.(metadata))

        tags = Map.new(tags, &{&1, Map.get(tag_values, &1, "")})

        Peep.insert_metric(name, metric, value, tags)
      end
    end
  end

  defp handler_id(event_name, peep_name) do
    {__MODULE__, peep_name, event_name}
  end

  defp keep?(nil, _metadata), do: true
  defp keep?(keep, metadata), do: keep.(metadata)

  defp fetch_measurement(%Counter{}, _measurements, _metadata) do
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
          %{^key => nil} -> 1
          %{^key => false} -> 1
          %{^key => value} -> value
          _ -> 1
        end
    end
  end

  defp allow_metric?(%Summary{} = metric) do
    Logger.warning("The summary metric type is unsupported. Dropping #{inspect(metric.name)}")
    false
  end

  defp allow_metric?(%Distribution{reporter_options: opts} = metric) do
    key = :max_value

    case Keyword.get(opts, key) do
      nil ->
        true

      n when is_number(n) ->
        true

      _ ->
        Logger.warning(
          "Distributions must have a numeric value assigned to #{inspect(key)} in reporter_options. Dropping #{inspect(metric.name)}"
        )

        false
    end
  end

  defp allow_metric?(_) do
    true
  end
end
