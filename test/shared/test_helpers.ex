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
            insert_one(storage_mod, storage, id, metric, value, tags)

          :error ->
            nil
        end

      _ ->
        nil
    end
  end

  def insert_metric(_name, _metric, _value, _tags), do: nil

  defp insert_one(storage_mod, storage, id, metric, value, tags) do
    resolved = storage_mod.resolve(storage)

    case Peep.Storage.insert_shape(storage_mod) do
      :batched -> storage_mod.insert_metrics(resolved, {tags}, [{id, metric, value, 0}])
      :per_metric -> storage_mod.insert_metric(resolved, id, metric, value, tags)
    end
  end

  defp find_metric_id(ids_to_metrics, metric) do
    find_metric_id(ids_to_metrics, metric, tuple_size(ids_to_metrics), 0)
  end

  defp find_metric_id(_tuple, _metric, size, size), do: :error

  defp find_metric_id(tuple, metric, size, idx) do
    case elem(tuple, idx) do
      ^metric -> {:ok, idx}
      _ -> find_metric_id(tuple, metric, size, idx + 1)
    end
  end

  def fresh_id do
    :"#{System.unique_integer([:positive])}"
  end

  def start_peep!(options) do
    name = fresh_id()
    {:ok, _pid} = Peep.start_link(Keyword.put(options, :name, name))
    name
  end

  @doc """
  The scraped series of `dist` after it records `values`: every bucket its
  calculator defines, labelled by `c:Peep.Buckets.upper_bound/2`, plus
  `:infinity` and `:sum`.
  """
  def distribution_series(%Metrics.Distribution{} = dist, values) do
    {mod, config} = Peep.Buckets.config(dist)
    n = mod.number_of_buckets(config)

    empty =
      0..(n - 1)//1
      |> Map.new(&{mod.upper_bound(&1, config), 0})
      |> Map.merge(%{infinity: 0, sum: 0})

    Enum.reduce(values, empty, fn value, series ->
      idx = mod.bucket_for(value, config)
      label = if idx < n, do: mod.upper_bound(idx, config), else: :infinity

      %{series | label => series[label] + 1, sum: series.sum + round(value)}
    end)
  end
end
