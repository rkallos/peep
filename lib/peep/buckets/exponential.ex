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
