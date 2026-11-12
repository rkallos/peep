defmodule BucketsTest do
  use ExUnit.Case, async: true

  defmodule CustomBuckets do
    use Peep.Buckets.Custom, buckets: [3.14, 3.5, 4, 8, 15, 16, 23, 42, 50.5, 60]
  end

  defmodule ManyBuckets do
    use Peep.Buckets.Custom, buckets: Enum.map(1..20, &(&1 * 10))
  end

  alias Peep.Buckets.Exponential
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

    assert CustomBuckets.config(dist) == %{}

    check(CustomBuckets,
      exp_buckets: %{
        3 => 0,
        3.13 => 0,
        3.14 => 1,
        3.49 => 1,
        3.50 => 2,
        5 => 3,
        14 => 4,
        15 => 5,
        16 => 6,
        22 => 6,
        23 => 7,
        41 => 7,
        42 => 8,
        43 => 8,
        50 => 8,
        50.4 => 8,
        50.5 => 9,
        51 => 9,
        1_000 => 10
      },
      exp_upper_bounds: %{
        0 => 3.14,
        1 => 3.5,
        2 => 4.0,
        3 => 8.0,
        4 => 15.0,
        5 => 16.0,
        6 => 23.0,
        7 => 42.0,
        8 => 50.5,
        9 => 60.0,
        1_000 => :infinity
      }
    )
  end

  test "more than 16 custom buckets are searched as a tree" do
    check(ManyBuckets,
      exp_buckets:
        Map.merge(
          Map.new(0..210, &{&1, min(div(&1, 10), 20)}),
          %{9.99 => 0, 10.0 => 1, 155.5 => 15, 199.99 => 19, 200.0 => 20, 1.0e6 => 20}
        ),
      exp_upper_bounds: %{0 => 10.0, 9 => 100.0, 19 => 200.0, 20 => :infinity}
    )
  end

  test "passing a non-number to `use Peep.Buckets.Custom` fails to compile" do
    assert_raise ArgumentError, fn -> custom_buckets([1, 2, 3, :four, 5]) end
  end

  test "buckets passed to `Peep.Buckets.Custom` can be values to be computed" do
    quote(do: [:timer.seconds(1), :timer.seconds(2), :timer.seconds(5)])
    |> custom_buckets()
    |> check(exp_buckets: %{999 => 0, 1_000 => 1, 2_000 => 2, 5_000 => 3})
  end

  test "whole list may be a set of computable values" do
    quote(do: Enum.map(1..10, &:timer.seconds/1))
    |> custom_buckets()
    |> check(exp_buckets: %{999 => 0, 1_000 => 1, 9_999 => 9, 10_000 => 10})
  end

  test "buckets can be read from variable" do
    quote do
      buckets = Enum.map(1..10, &:timer.seconds/1)
      use Peep.Buckets.Custom, buckets: buckets
    end
    |> compile_module()
    |> check(exp_buckets: %{999 => 0, 1_000 => 1, 9_999 => 9, 10_000 => 10})
  end

  test "buckets passed to `use Peep.Buckets.Custom` are deduplicated" do
    module = custom_buckets([1, 1, 1.0, 2, 2.0, 3])

    assert module.number_of_buckets(%{}) == 3
    check(module, exp_buckets: %{0 => 0, 1 => 1, 2 => 2, 3 => 3})
  end

  test "each exponential boundary is the smallest float above its bucket" do
    for opts <- [
          [],
          [max_value: 1000],
          [bucket_variability: 0.25],
          [max_value: 1.0e12, bucket_variability: 0.01]
        ] do
      dist = Metrics.distribution("buckets.test.exponential", reporter_options: opts)
      config = Exponential.config(dist)
      boundaries = Exponential.boundaries(config)

      assert length(boundaries) == Exponential.number_of_buckets(config)

      for {boundary, idx} <- Enum.with_index(boundaries) do
        assert Exponential.bucket_for(boundary, config) == idx + 1
        assert Exponential.bucket_for(float_below(boundary), config) == idx
      end
    end
  end

  defp float_below(x) do
    <<bits::unsigned-integer-64>> = <<x::float-64>>
    <<below::float-64>> = <<bits - 1::unsigned-integer-64>>
    below
  end

  defp custom_buckets(buckets) do
    compile_module(quote(do: use(Peep.Buckets.Custom, buckets: unquote(buckets))))
  end

  defp compile_module(body) do
    name = Module.concat(__MODULE__, "Compiled#{System.unique_integer([:positive])}")

    [{module, _binary}] =
      Code.compile_quoted(quote(do: defmodule(unquote(name), do: unquote(body))))

    module
  end

  defp check(mod, opts) do
    exp_buckets = Keyword.fetch!(opts, :exp_buckets)
    exp_upper_bounds = Keyword.get(opts, :exp_upper_bounds, %{})

    assert Map.new(exp_buckets, fn {value, _} -> {value, mod.bucket_for(value, %{})} end) ==
             exp_buckets

    assert Map.new(exp_upper_bounds, fn {idx, _} -> {idx, mod.upper_bound(idx, %{})} end) ==
             exp_upper_bounds
  end
end
