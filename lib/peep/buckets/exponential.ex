defmodule Peep.Buckets.Exponential do
  @default_max_value 1_000_000_000
  @default_bucket_variability 0.10

  @moduledoc """
  The default bucketing strategy in Peep, based on the logarithmic bucketing
  scheme in the DDSketch paper.

  This bucketing scheme takes two parameters:

  1. `max_value` - a maximum expected value. Defaults to #{@default_max_value}.
  2. `bucket_variability` - a percentage reflecting roughly half the amount by
  which bucket ranges should grow. Defaults to #{@default_bucket_variability}.
  """

  @behaviour Peep.Buckets

  alias Telemetry.Metrics

  @impl true
  def boundaries(config) do
    for i <- 0..(number_of_buckets(config) - 1), do: first_above(i, config)
  end

  # The smallest float that bucket_for/2 puts above bucket i. Its rounding
  # moves that float a few floats away from gamma^i.
  defp first_above(i, %{gamma: gamma} = config) do
    :math.pow(gamma, i)
    |> step_while(-1, &(bucket_for(&1, config) > i))
    |> step_while(1, &(bucket_for(&1, config) <= i))
  end

  defp step_while(x, step, continue?) do
    case continue?.(x) do
      true -> step_while(adjacent_float(x, step), step, continue?)
      false -> x
    end
  end

  defp adjacent_float(x, step) when is_float(x) and x > 0.0 do
    <<bits::unsigned-integer-64>> = <<x::float-64>>
    <<adjacent::float-64>> = <<bits + step::unsigned-integer-64>>
    adjacent
  end

  @impl true
  def config(%Metrics.Distribution{reporter_options: opts}) do
    max_value =
      Keyword.get(opts, :max_value, @default_max_value)

    bucket_variability =
      Keyword.get(opts, :bucket_variability, @default_bucket_variability)

    gamma = (1 + bucket_variability) / (1 - bucket_variability)
    log_gamma = :math.log(gamma)

    %{
      max_value: max_value,
      gamma: gamma,
      log_gamma: log_gamma
    }
  end

  @impl true
  def number_of_buckets(%{max_value: max_value} = config) do
    bucket_for(max_value, config) + 1
  end

  @impl true
  def bucket_for(value, _) when value < 1 do
    0
  end

  def bucket_for(value, %{log_gamma: log_gamma}) do
    max(ceil(:math.log(value) / log_gamma), 0)
  end

  @impl true
  def upper_bound(bucket, %{gamma: gamma}) do
    :math.pow(gamma, bucket)
    |> :erlang.float_to_binary([:compact, {:decimals, 6}])
  end
end
