defmodule Peep.Test do
  @moduledoc false
  alias Telemetry.Metrics

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
