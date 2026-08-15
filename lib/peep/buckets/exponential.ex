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

  # `Peep.Buckets.boundaries/1`'s contract is exclusive-upper: a value
  # belongs to the first bucket whose boundary it is strictly less than
  # (matching `Peep.Buckets.Custom`'s own `val < boundary` clauses).
  # `bucket_for/2` below is inclusive-upper instead (a value exactly equal
  # to `gamma^bucket` stays in `bucket`, via `ceil/1`), so each boundary
  # here is bumped to the next representable float above the true
  # threshold - the exact technique for turning an inclusive floating-point
  # bound into an exclusive one, not an approximation: since there is no
  # representable float strictly between `x` and `next_up(x)`, `value <
  # next_up(x)` is true for exactly the same values as `value <= x`.
  @impl true
  def boundaries(%{gamma: gamma} = config) do
    for i <- 0..(number_of_buckets(config) - 1) do
      next_up(:math.pow(gamma, i))
    end
  end

  # The bit pattern of a positive, finite IEEE 754 double, read as an
  # unsigned integer, is monotonically increasing with the float's value -
  # incrementing it by one steps to the next representable float up.
  # `gamma^i` is always positive (gamma > 1, i >= 0), so the general case
  # (negative numbers, zero, infinities) doesn't need handling here.
  defp next_up(x) when is_float(x) and x > 0.0 do
    <<bits::unsigned-integer-64>> = <<x::float-64>>
    <<next::float-64>> = <<bits + 1::unsigned-integer-64>>
    next
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
