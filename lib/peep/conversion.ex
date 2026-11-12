defmodule Peep.Conversion do
  @moduledoc false

  alias Telemetry.Metrics

  @doc """
  The `:peep_export_conversion_factor` of a metric. Counters have none.
  """
  @spec factor(Metrics.t()) :: number()
  def factor(%Metrics.Counter{}), do: 1

  def factor(%{reporter_options: reporter_options}) do
    Keyword.get(reporter_options, :peep_export_conversion_factor, 1)
  end

  @doc """
  Converts a stored value, or the bound of a bucket, to the unit it is exported in.
  """
  @spec convert(number(), number()) :: number()
  def convert(value, factor) when is_number(factor), do: value * factor
end
