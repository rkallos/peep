defmodule StatsdCacheTest do
  use ExUnit.Case

  alias Peep.Statsd.Cache
  alias Telemetry.Metrics

  alias Peep.Support.StorageCounter

  @impls [:default, :striped, :fast_dist, :ordered_set]

  for impl <- @impls do
    test "#{impl} - a counter with no increments is omitted from delta" do
      name = StorageCounter.fresh_id()

      counter = Metrics.counter("cache.test.counter")

      opts = [
        name: name,
        metrics: [counter],
        storage: unquote(impl)
      ]

      {:ok, _pid} = Peep.start_link(opts)

      Peep.insert_metric(name, counter, 1, %{})

      {delta_one, cache_one} = calculate_deltas_and_replacement(cache_of(name), Cache.new([]))

      assert Map.values(delta_one) == [1]

      {delta_two, cache_two} = calculate_deltas_and_replacement(cache_of(name), cache_one)

      assert Map.values(delta_two) == []

      Peep.insert_metric(name, counter, 1, %{})
      {delta_three, _cache_three} = calculate_deltas_and_replacement(cache_of(name), cache_two)

      assert Map.values(delta_three) == [1]
    end

    test "#{impl} - a sum with no increments is omitted from delta" do
      name = StorageCounter.fresh_id()

      sum = Metrics.sum("cache.test.counter")

      opts = [
        name: name,
        metrics: [sum],
        storage: unquote(impl)
      ]

      {:ok, _pid} = Peep.start_link(opts)

      Peep.insert_metric(name, sum, 10, %{})

      {delta_one, cache_one} = calculate_deltas_and_replacement(cache_of(name), Cache.new([]))

      assert Map.values(delta_one) == [10]

      {delta_two, cache_two} = calculate_deltas_and_replacement(cache_of(name), cache_one)

      assert Map.values(delta_two) == []

      Peep.insert_metric(name, sum, 10, %{})
      {delta_three, _cache_three} = calculate_deltas_and_replacement(cache_of(name), cache_two)

      assert Map.values(delta_three) == [10]
    end

    test "#{impl} - a distribution with no samples is omitted from delta" do
      name = StorageCounter.fresh_id()

      dist = Metrics.distribution("cache.test.dist", reporter_options: [max_value: 1000])

      opts = [
        name: name,
        metrics: [dist],
        storage: unquote(impl)
      ]

      {:ok, _pid} = Peep.start_link(opts)

      Peep.insert_metric(name, dist, 500, %{})
      Peep.insert_metric(name, dist, 500, %{})
      Peep.insert_metric(name, dist, 500, %{})

      {delta_one, cache_one} = calculate_deltas_and_replacement(cache_of(name), Cache.new([]))

      assert Map.values(delta_one) == [3]

      {delta_two, cache_two} = calculate_deltas_and_replacement(cache_of(name), cache_one)

      assert Map.values(delta_two) == []

      Peep.insert_metric(name, dist, 500, %{})
      Peep.insert_metric(name, dist, 500, %{})
      Peep.insert_metric(name, dist, 1000, %{})
      {delta_three, _cache_three} = calculate_deltas_and_replacement(cache_of(name), cache_two)

      assert Map.values(delta_three) |> Enum.sort() == [1, 2]
    end

    test "#{impl} - a last_value with no changes is included in deltas" do
      name = StorageCounter.fresh_id()

      last_value = Metrics.last_value("cache.test.gauge")

      opts = [
        name: name,
        metrics: [last_value],
        storage: unquote(impl)
      ]

      {:ok, _pid} = Peep.start_link(opts)

      Peep.insert_metric(name, last_value, 10, %{})

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
