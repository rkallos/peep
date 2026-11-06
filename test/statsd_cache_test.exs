defmodule StatsdCacheTest do
  use ExUnit.Case, async: true

  alias Peep.Statsd.Cache
  alias Telemetry.Metrics

  test "a counter with no increments is omitted from delta" do
    counter = Metrics.counter("cache.test.counter")

    check(
      scrapes: [
        %{counter => %{%{} => 1}},
        %{counter => %{%{} => 1}},
        %{counter => %{%{} => 2}}
      ],
      exp_deltas: [
        %{counter => %{%{} => 1}},
        %{},
        %{counter => %{%{} => 1}}
      ]
    )
  end

  test "a sum with no increments is omitted from delta" do
    sum = Metrics.sum("cache.test.sum")

    check(
      scrapes: [
        %{sum => %{%{} => 10}},
        %{sum => %{%{} => 10}},
        %{sum => %{%{} => 20}}
      ],
      exp_deltas: [
        %{sum => %{%{} => 10}},
        %{},
        %{sum => %{%{} => 10}}
      ]
    )
  end

  test "a distribution with no samples is omitted from delta" do
    dist = Metrics.distribution("cache.test.dist", reporter_options: [max_value: 1000])

    check(
      scrapes: [
        %{dist => %{%{} => Peep.Test.distribution_series(dist, [500, 500, 500])}},
        %{dist => %{%{} => Peep.Test.distribution_series(dist, [500, 500, 500])}},
        %{dist => %{%{} => Peep.Test.distribution_series(dist, [500, 500, 500, 500, 500, 1000])}}
      ],
      exp_deltas: [
        %{dist => %{%{} => changed_buckets(dist, [500, 500, 500])}},
        %{},
        %{dist => %{%{} => changed_buckets(dist, [500, 500, 1000])}}
      ]
    )
  end

  test "a last_value with no changes is included in deltas" do
    last_value = Metrics.last_value("cache.test.gauge")

    check(
      scrapes: [
        %{last_value => %{%{} => 10}},
        %{last_value => %{%{} => 10}}
      ],
      exp_deltas: [
        %{last_value => %{%{} => 10}},
        %{last_value => %{%{} => 10}}
      ]
    )
  end

  defp check(scrapes: scrapes, exp_deltas: exp_deltas) do
    Enum.zip(scrapes, exp_deltas)
    |> Enum.reduce(Cache.new([]), fn {scrape, exp_delta}, cache_old ->
      cache_new = Cache.new(scrape)
      delta = Cache.calculate_deltas(cache_new, cache_old)

      assert delta == Cache.new(exp_delta).kv

      Cache.replace(cache_old, Map.keys(delta), cache_new)
    end)
  end

  defp changed_buckets(dist, values) do
    dist
    |> Peep.Test.distribution_series(values)
    |> Map.reject(fn {_bucket, count} -> count == 0 end)
  end
end
