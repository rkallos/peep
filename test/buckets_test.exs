defmodule BucketsTest do
  use ExUnit.Case

  defmodule CustomBuckets do
    use Peep.Buckets.Custom, buckets: [3.14, 3.5, 4, 8, 15, 16, 23, 42, 50.5, 60]
  end

  alias Telemetry.Metrics

  test "custom buckets #1" do
    dist =
      Metrics.distribution("prometheus.test.distribution",
        description: "a distribution",
        reporter_options: [
          max_value: 1000,
          peep_bucket_calculator: CustomBuckets
        ]
      )

    config = CustomBuckets.config(dist)

    assert config == %{}

    assert CustomBuckets.bucket_for(3, config) == 0
    assert CustomBuckets.bucket_for(3.13, config) == 0
    assert CustomBuckets.bucket_for(3.14, config) == 1
    assert CustomBuckets.bucket_for(3.49, config) == 1
    assert CustomBuckets.bucket_for(3.50, config) == 2
    assert CustomBuckets.bucket_for(5, config) == 3
    assert CustomBuckets.bucket_for(14, config) == 4
    assert CustomBuckets.bucket_for(15, config) == 5
    assert CustomBuckets.bucket_for(16, config) == 6
    assert CustomBuckets.bucket_for(22, config) == 6
    assert CustomBuckets.bucket_for(23, config) == 7
    assert CustomBuckets.bucket_for(41, config) == 7
    assert CustomBuckets.bucket_for(42, config) == 8
    assert CustomBuckets.bucket_for(43, config) == 8
    assert CustomBuckets.bucket_for(50, config) == 8
    assert CustomBuckets.bucket_for(50.4, config) == 8
    assert CustomBuckets.bucket_for(50.5, config) == 9
    assert CustomBuckets.bucket_for(51, config) == 9
    assert CustomBuckets.bucket_for(1_000, config) == 10

    assert CustomBuckets.upper_bound(0, config) == "3.14"
    assert CustomBuckets.upper_bound(1, config) == "3.5"
    assert CustomBuckets.upper_bound(2, config) == "4.0"
    assert CustomBuckets.upper_bound(3, config) == "8.0"
    assert CustomBuckets.upper_bound(4, config) == "15.0"
    assert CustomBuckets.upper_bound(5, config) == "16.0"
    assert CustomBuckets.upper_bound(6, config) == "23.0"
    assert CustomBuckets.upper_bound(7, config) == "42.0"
    assert CustomBuckets.upper_bound(8, config) == "50.5"
    assert CustomBuckets.upper_bound(9, config) == "60.0"
    assert CustomBuckets.upper_bound(1_000, config) == "+Inf"
  end

  test "passing a non-number to `use Peep.Buckets.Custom` fails to compile" do
    ast =
      quote do
        defmodule BadBuckets do
          use Peep.Buckets.Custom, buckets: [1, 2, 3, :four, 5]
        end
      end

    assert_raise ArgumentError, fn -> Code.compile_quoted(ast) end
  end

  test "buckets passed to `Peep.Buckets.Custom` can be values to be computed" do
    ast =
      quote do
        defmodule CompTimeValues do
          use Peep.Buckets.Custom,
            buckets: [
              :timer.seconds(1),
              :timer.seconds(2),
              :timer.seconds(5)
            ]
        end
      end

    assert Code.compile_quoted(ast)
  end

  test "whole list may be a set of computable values" do
    ast =
      quote do
        defmodule CompTimeList do
          use Peep.Buckets.Custom,
            buckets: Enum.map(1..10, &:timer.seconds/1)
        end
      end

    assert Code.compile_quoted(ast)
  end

  test "buckets can be read from variable" do
    ast =
      quote do
        defmodule VariableList do
          buckets = Enum.map(1..10, &:timer.seconds/1)

          use Peep.Buckets.Custom,
            buckets: buckets
        end
      end

    assert Code.compile_quoted(ast)
  end

  test "buckets passed to `use Peep.Buckets.Custom` are deduplicated" do
    [{module, _binary}] =
      quote do
        defmodule DupeBuckets do
          use Peep.Buckets.Custom, buckets: [1, 1, 1.0, 2, 2.0, 3]
        end
      end
      |> Code.compile_quoted()

    assert 3 = module.number_of_buckets(%{})
    assert 0 = module.bucket_for(0, %{})
    assert 1 = module.bucket_for(1, %{})
    assert 2 = module.bucket_for(2, %{})
    assert 3 = module.bucket_for(3, %{})
  end
end
