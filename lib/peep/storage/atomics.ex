defmodule Peep.Storage.Atomics do
  @moduledoc false

  defstruct [
    :gamma,
    :num_buckets,
    :buckets,
    :sum,
    :above_max
  ]

  def new(max_value, gamma) do
    num_buckets = calculate_bucket(max_value, gamma) + 1
    buckets = :atomics.new(num_buckets, signed: false)
    sum = :atomics.new(1, signed: false)
    above_max = :atomics.new(1, signed: false)

    %__MODULE__{
      gamma: gamma,
      num_buckets: num_buckets,
      buckets: buckets,
      sum: sum,
      above_max: above_max
    }
  end

  def insert(
        %__MODULE__{
          gamma: gamma,
          buckets: buckets,
          sum: sum,
          num_buckets: num_buckets,
          above_max: above_max
        },
        value
      ) do
    # :atomics indexes are 1-based.
    # 1 is added for when calculate_bucket/2 returns 0
    bucket_idx = calculate_bucket(value, gamma) + 1

    case bucket_idx > num_buckets do
      true ->
        :atomics.add(above_max, 1, 1)

      false ->
        :atomics.add(buckets, bucket_idx, 1)
    end

    :atomics.add(sum, 1, round(value))
  end

  def values(%__MODULE__{
        gamma: gamma,
        buckets: buckets,
        sum: sum,
        above_max: above_max,
        num_buckets: num_buckets
      }) do
    map =
      for idx <- 1..num_buckets, into: %{} do
        {bucket_idx_to_upper_bound(idx, gamma), :atomics.get(buckets, idx)}
      end

    map
    |> Map.put_new(:infinity, :atomics.get(above_max, 1))
    |> Map.put_new(:sum, :atomics.get(sum, 1))
  end

  defp bucket_idx_to_upper_bound(idx, gamma) do
    # :atomics indexes are 1-based.
    # 1 is removed for when log(gamma, value) is 0
    format_bucket_upper_bound(:math.pow(gamma, idx - 1))
  end

  defp format_bucket_upper_bound(ub) do
    :erlang.float_to_binary(ub, [:compact, {:decimals, 6}])
  end

  defp calculate_bucket(value, _gamma) when value == 0 do
    0
  end

  defp calculate_bucket(value, gamma) do
    max(ceil(:math.log(value) / :math.log(gamma)), 0)
  end
end
