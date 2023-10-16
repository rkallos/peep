defmodule StatsdCacheTest do
  use ExUnit.Case

  alias Peep.Storage
  alias Peep.Statsd.Cache
  alias Telemetry.Metrics

  alias Peep.Support.StorageCounter

  test "a counter with no increments is omitted from delta" do
    tid = Storage.new(StorageCounter.fresh_id())

    counter = Metrics.counter("cache.test.counter")

    Storage.insert_metric(tid, counter, 1, [])

    {delta_one, cache_one} = calculate_deltas_and_replacement(cache_of(tid), Cache.new([]))

    assert Map.values(delta_one) == [1]

    {delta_two, cache_two} = calculate_deltas_and_replacement(cache_of(tid), cache_one)

    assert Map.values(delta_two) == []

    Storage.insert_metric(tid, counter, 1, [])
    {delta_three, _cache_three} = calculate_deltas_and_replacement(cache_of(tid), cache_two)

    assert Map.values(delta_three) == [1]
  end

  test "a sum with no increments is omitted from delta" do
    tid = Storage.new(StorageCounter.fresh_id())

    sum = Metrics.sum("cache.test.counter")

    Storage.insert_metric(tid, sum, 10, [])

    {delta_one, cache_one} = calculate_deltas_and_replacement(cache_of(tid), Cache.new([]))

    assert Map.values(delta_one) == [10]

    {delta_two, cache_two} = calculate_deltas_and_replacement(cache_of(tid), cache_one)

    assert Map.values(delta_two) == []

    Storage.insert_metric(tid, sum, 10, [])
    {delta_three, _cache_three} = calculate_deltas_and_replacement(cache_of(tid), cache_two)

    assert Map.values(delta_three) == [10]
  end

  test "a distribution with no samples is omitted from delta" do
    tid = Storage.new(StorageCounter.fresh_id())

    dist = Metrics.distribution("cache.test.dist", reporter_options: [max_value: 1000])

    Storage.insert_metric(tid, dist, 500, [])
    Storage.insert_metric(tid, dist, 500, [])
    Storage.insert_metric(tid, dist, 500, [])

    {delta_one, cache_one} = calculate_deltas_and_replacement(cache_of(tid), Cache.new([]))

    assert Map.values(delta_one) == [3]

    {delta_two, cache_two} = calculate_deltas_and_replacement(cache_of(tid), cache_one)

    assert Map.values(delta_two) == []

    Storage.insert_metric(tid, dist, 500, [])
    Storage.insert_metric(tid, dist, 500, [])
    Storage.insert_metric(tid, dist, 1000, [])
    {delta_three, _cache_three} = calculate_deltas_and_replacement(cache_of(tid), cache_two)

    assert Map.values(delta_three) |> Enum.sort() == [1, 2]
  end

  test "a last_value with no changes is included in deltas" do
    tid = Storage.new(StorageCounter.fresh_id())

    last_value = Metrics.last_value("cache.test.gauge")

    Storage.insert_metric(tid, last_value, 10, [])

    {delta_one, cache_one} = calculate_deltas_and_replacement(cache_of(tid), Cache.new([]))

    assert Map.values(delta_one) == [10]

    {delta_two, _cache_two} = calculate_deltas_and_replacement(cache_of(tid), cache_one)

    assert Map.values(delta_two) == [10]
  end

  defp cache_of(tid) do
    Storage.get_all_metrics(tid)
    |> Cache.new()
  end

  defp calculate_deltas_and_replacement(cache_new, cache_old) do
    delta = Cache.calculate_deltas(cache_new, cache_old)
    keys = Map.keys(delta)
    replacement = Cache.replace(cache_old, keys, cache_new)
    {delta, replacement}
  end
end
