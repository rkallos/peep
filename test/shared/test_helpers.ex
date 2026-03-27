defmodule Peep.Test do
  @moduledoc false
  alias Telemetry.Metrics
  require Peep.Persistent

  def insert_metric(name, metric, value, tags) when is_number(value) do
    case Peep.Persistent.fetch(name) do
      Peep.Persistent.persistent(
        storage: {storage_mod, storage},
        ids_to_metrics: ids_to_metrics
      ) ->
        case find_metric_id(ids_to_metrics, metric) do
          {:ok, id} ->
            storage
            |> storage_mod.resolve()
            |> storage_mod.insert_metric(id, metric, value, tags)

          :error ->
            nil
        end

      _ ->
        nil
    end
  end

  def insert_metric(_name, _metric, _value, _tags), do: nil

  defp find_metric_id(ids_to_metrics, metric) do
    Enum.find_value(ids_to_metrics, :error, fn
      {id, ^metric} -> {:ok, id}
      _ -> nil
    end)
  end

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
