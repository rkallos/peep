defmodule Peep.Test do
  @moduledoc false
  alias Telemetry.Metrics
  require Peep.Persistent

  def insert_metric(name, metric, value, tags) when is_number(value) do
    case Peep.Persistent.fetch(name) do
      Peep.Persistent.persistent(
        storage: {storage_mod, storage},
        metrics_to_ids: %{^metric => id}
      ) ->
        storage
        |> storage_mod.resolve()
        |> storage_mod.insert_metric(id, metric, value, tags)

      _ ->
        nil
    end
  end

  def insert_metric(_name, _metric, _value, _tags), do: nil

  def fresh_id do
    :"#{System.unique_integer([:positive])}"
  end

  def start_peep!(options) do
    name = fresh_id()
    {:ok, _pid} = Peep.start_link(Keyword.put(options, :name, name))
    name
  end

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
