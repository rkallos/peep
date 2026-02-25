defmodule Peep.Test do
  @moduledoc false
  alias Telemetry.Metrics

  def get_metric(all_metrics, metric, tags) do
    tags = to_map(tags)
    tags_map = Map.get(all_metrics, metric, %{})

    case metric do
      %Metrics.Counter{} -> Map.get(tags_map, tags, 0)
      %Metrics.Sum{} -> Map.get(tags_map, tags, 0)
      _other -> Map.get(tags_map, tags)
    end
  end

  defp to_map(tags) when is_map(tags), do: tags
  defp to_map(tags) when is_list(tags), do: Map.new(tags)
end
