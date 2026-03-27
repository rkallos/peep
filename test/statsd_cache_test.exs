defmodule StatsdCacheTest do
  use ExUnit.Case

  alias Peep.Statsd.Cache
  alias Telemetry.Metrics

  @impls [:default, :striped]

  for impl <- @impls do
    test "#{impl} - a counter with no increments is omitted from delta" do
      counter = Metrics.counter("cache.test.counter")
      name = Peep.Test.start_peep!(metrics: [counter], storage: unquote(impl))

      Peep.Test.insert_metric(name, counter, 1, %{})

      {delta_one, cache_one} = calculate_deltas_and_replacement(cache_of(name), Cache.new([]))

      assert Map.values(delta_one) == [1]

      {delta_two, cache_two} = calculate_deltas_and_replacement(cache_of(name), cache_one)

      assert Map.values(delta_two) == []

      Peep.Test.insert_metric(name, counter, 1, %{})
      {delta_three, _cache_three} = calculate_deltas_and_replacement(cache_of(name), cache_two)

      assert Map.values(delta_three) == [1]
    end

    test "#{impl} - a sum with no increments is omitted from delta" do
      sum = Metrics.sum("cache.test.counter")
      name = Peep.Test.start_peep!(metrics: [sum], storage: unquote(impl))

      Peep.Test.insert_metric(name, sum, 10, %{})

      {delta_one, cache_one} = calculate_deltas_and_replacement(cache_of(name), Cache.new([]))

      assert Map.values(delta_one) == [10]

      {delta_two, cache_two} = calculate_deltas_and_replacement(cache_of(name), cache_one)

      assert Map.values(delta_two) == []

      Peep.Test.insert_metric(name, sum, 10, %{})
      {delta_three, _cache_three} = calculate_deltas_and_replacement(cache_of(name), cache_two)

      assert Map.values(delta_three) == [10]
    end

    test "#{impl} - a distribution with no samples is omitted from delta" do
      dist = Metrics.distribution("cache.test.dist", reporter_options: [max_value: 1000])
      name = Peep.Test.start_peep!(metrics: [dist], storage: unquote(impl))

      Peep.Test.insert_metric(name, dist, 500, %{})
      Peep.Test.insert_metric(name, dist, 500, %{})
      Peep.Test.insert_metric(name, dist, 500, %{})

      {delta_one, cache_one} = calculate_deltas_and_replacement(cache_of(name), Cache.new([]))

      assert Map.values(delta_one) == [3]

      {delta_two, cache_two} = calculate_deltas_and_replacement(cache_of(name), cache_one)

      assert Map.values(delta_two) == []

      Peep.Test.insert_metric(name, dist, 500, %{})
      Peep.Test.insert_metric(name, dist, 500, %{})
      Peep.Test.insert_metric(name, dist, 1000, %{})
      {delta_three, _cache_three} = calculate_deltas_and_replacement(cache_of(name), cache_two)

      assert Map.values(delta_three) |> Enum.sort() == [1, 2]
    end

    test "#{impl} - a last_value with no changes is included in deltas" do
      last_value = Metrics.last_value("cache.test.gauge")
      name = Peep.Test.start_peep!(metrics: [last_value], storage: unquote(impl))

      Peep.Test.insert_metric(name, last_value, 10, %{})

      {delta_one, cache_one} = calculate_deltas_and_replacement(cache_of(name), Cache.new([]))

      assert Map.values(delta_one) == [10]

      {delta_two, _cache_two} = calculate_deltas_and_replacement(cache_of(name), cache_one)

      assert Map.values(delta_two) == [10]
    end
  end

  defp cache_of(name) do
    Peep.get_all_metrics(name)
    |> Cache.new()
  end

  defp calculate_deltas_and_replacement(cache_new, cache_old) do
    delta = Cache.calculate_deltas(cache_new, cache_old)
    keys = Map.keys(delta)
    replacement = Cache.replace(cache_old, keys, cache_new)
    {delta, replacement}
  end
end
