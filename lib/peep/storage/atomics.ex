defmodule Peep.Storage.Atomics do
  @moduledoc false

  defstruct [
    :num_buckets,
    :buckets,
    :sum,
    :above_max,
    :bucket_calculator
  ]

  def new(%Telemetry.Metrics.Distribution{} = metric) do
    {bucket_calculator, config} = Peep.Buckets.config(metric)
    num_buckets = bucket_calculator.number_of_buckets(config)
    buckets = :atomics.new(num_buckets, signed: false)
    sum = :atomics.new(1, signed: true)
    above_max = :atomics.new(1, signed: false)

    %__MODULE__{
      num_buckets: num_buckets,
      buckets: buckets,
      sum: sum,
      above_max: above_max,
      bucket_calculator: {bucket_calculator, config}
    }
  end

  def insert(
        %__MODULE__{
          bucket_calculator: {module, config},
          buckets: buckets,
          sum: sum,
          num_buckets: num_buckets,
          above_max: above_max
        },
        value
      ) do
    # :atomics indexes are 1-based.
    # 1 is added for when calculate_bucket/2 returns 0
    bucket_idx = module.bucket_for(value, config) + 1

    case bucket_idx > num_buckets do
      true ->
        :atomics.add(above_max, 1, 1)

      false ->
        :atomics.add(buckets, bucket_idx, 1)
    end

    :atomics.add(sum, 1, round(value))
  end

  def values(%__MODULE__{
        bucket_calculator: {module, config},
        buckets: buckets,
        sum: sum,
        above_max: above_max,
        num_buckets: num_buckets
      }) do
    map =
      for idx <- 1..num_buckets, into: %{} do
        {module.upper_bound(idx - 1, config), :atomics.get(buckets, idx)}
      end

    map
    |> Map.put_new(:infinity, :atomics.get(above_max, 1))
    |> Map.put_new(:sum, :atomics.get(sum, 1))
  end
end
