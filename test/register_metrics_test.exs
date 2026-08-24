defmodule Peep.Storage.RegisterMetricsTest do
  use ExUnit.Case, async: true

  alias Telemetry.Metrics

  defmodule UnsortedBuckets do
    @behaviour Peep.Buckets

    @boundaries [1000, 10, 1, 10.0, 100]
    @labels ["big", "ten", "one", "ten again", "big"]

    @impl true
    def config(_), do: %{}

    @impl true
    def boundaries(_), do: @boundaries

    @impl true
    def number_of_buckets(_), do: length(@boundaries)

    @impl true
    def bucket_for(_, _), do: 0

    @impl true
    def upper_bound(idx, _), do: Enum.at(@labels, idx, "+Inf")
  end

  test "a backend exporting register_metrics/2 is passed the metrics at startup" do
    counter = Metrics.counter("register.test.counter")

    dist =
      Metrics.distribution("register.test.dist", reporter_options: [max_value: 1000])

    {mod, config} = Peep.Buckets.config(dist)

    buckets =
      mod.boundaries(config)
      |> Enum.with_index(fn bound, idx -> {bound * 1.0, mod.upper_bound(idx, config)} end)

    check(
      metrics: [counter, dist],
      exp_registered: {counter, Map.put(dist, :peep_buckets, buckets)}
    )
  end

  test "registered buckets are sorted, with no repeated bound or label" do
    dist =
      Metrics.distribution("register.test.unsorted",
        reporter_options: [peep_bucket_calculator: UnsortedBuckets]
      )

    check(
      metrics: [dist],
      exp_registered:
        {Map.put(dist, :peep_buckets, [{1.0, "one"}, {10.0, "ten"}, {1000.0, "big"}])}
    )
  end

  test "a backend that does not export register_metrics/2 still starts" do
    counter = Metrics.counter("register.test.plain")
    name = Peep.Test.start_peep!(storage: :default, metrics: [counter])
    assert is_map(Peep.get_all_metrics(name))
  end

  defp check(opts) do
    name =
      Peep.Test.start_peep!(
        storage: {CustomBatchedStorage, []},
        metrics: Keyword.fetch!(opts, :metrics)
      )

    {CustomBatchedStorage, tid} = Peep.Persistent.storage(name)

    assert CustomBatchedStorage.registered_metrics(tid) == Keyword.fetch!(opts, :exp_registered)
  end
end
