defmodule PeepCoverageTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Telemetry.Metrics
  alias Peep.Support.StorageCounter

  test "start_link returns error for invalid options" do
    assert {:error, _} = Peep.start_link(name: :invalid_opts_test)
  end

  test "allow_metric? rejects distribution with non-numeric max_value" do
    dist =
      Metrics.distribution("bad.dist",
        reporter_options: [max_value: "not_a_number"]
      )

    log =
      capture_log(fn ->
        refute Peep.allow_metric?(dist)
      end)

    assert log =~ "Dropping"
    assert log =~ "max_value"
  end

  test "insert_metric returns nil for non-numeric value" do
    name = StorageCounter.fresh_id()

    counter = Metrics.counter("coverage.counter", event_name: [name, :coverage_counter])
    {:ok, _pid} = Peep.start_link(name: name, metrics: [counter])

    assert nil == Peep.insert_metric(name, counter, "not_a_number", %{})
  end

  test "insert_metric returns nil for unknown metric" do
    name = StorageCounter.fresh_id()

    counter = Metrics.counter("known.counter", event_name: [name, :known])
    unknown = Metrics.counter("unknown.counter", event_name: [name, :unknown])

    {:ok, _pid} = Peep.start_link(name: name, metrics: [counter])

    assert nil == Peep.insert_metric(name, unknown, 1, %{})
  end

  test "get_all_metrics returns nil for unknown name" do
    assert nil == Peep.get_all_metrics(:nonexistent_peep_instance)
  end

  test "storage_size returns nil for unknown name" do
    assert nil == Peep.storage_size(:nonexistent_peep_instance)
  end

  test "prune_tags returns nil for unknown name" do
    assert nil == Peep.prune_tags(:nonexistent_peep_instance, [%{foo: :bar}])
  end

  test "worker with statsd config initializes statsd state and flush timer" do
    name = StorageCounter.fresh_id()

    opts = [
      name: name,
      metrics: [],
      statsd: [flush_interval_ms: 60_000, host: {127, 0, 0, 1}, port: 8125]
    ]

    {:ok, pid} = Peep.start_link(opts)
    state = :sys.get_state(pid)
    assert state.statsd_state != nil
    assert state.statsd_opts != nil
  end

  test "handle_info with unknown message does not crash" do
    name = StorageCounter.fresh_id()

    opts = [name: name, metrics: []]
    {:ok, pid} = Peep.start_link(opts)

    send(pid, :some_random_message)
    # Give it a moment to process
    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
  end
end
