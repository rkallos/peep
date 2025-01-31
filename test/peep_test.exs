defmodule PeepTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  doctest Peep

  alias Telemetry.Metrics

  test "a worker can be started" do
    options = [
      name: __MODULE__,
      metrics: []
    ]

    assert {:ok, pid} = Peep.start_link(options)
    assert Process.alive?(pid)
  end

  test "many workers can be started" do
    for i <- 1..10 do
      options = [
        name: :"#{__MODULE__}_#{i}",
        metrics: []
      ]

      assert {:ok, pid} = Peep.start_link(options)
      assert Process.alive?(pid)
    end
  end

  test "a worker with no statsd config has no statsd state" do
    options = [
      name: :"#{__MODULE__}_no_statsd",
      metrics: []
    ]

    assert {:ok, pid} = Peep.start_link(options)
    assert match?(%{statsd_state: nil}, :sys.get_state(pid))
  end

  test "a worker with non-empty global_tags applies to all metrics" do
    name = :"#{__MODULE__}_global_tags"

    tags = %{foo: "bar", baz: "quux"}
    tag_keys = [:foo, :baz]

    counter = Metrics.counter("peep.counter", event_name: [:counter], tags: tag_keys)
    sum = Metrics.sum("peep.sum", event_name: [:sum], measurement: :count, tags: tag_keys)

    last_value =
      Metrics.last_value("peep.gauge", event_name: [:gauge], measurement: :value, tags: tag_keys)

    distribution =
      Metrics.distribution("peep.dist",
        event_name: [:dist],
        measurement: :value,
        tags: tag_keys,
        reporter_options: [max_value: 100]
      )

    metrics = [counter, sum, last_value, distribution]

    options = [
      name: name,
      metrics: metrics,
      global_tags: tags
    ]

    assert {:ok, _pid} = Peep.start_link(options)
    :telemetry.execute([:counter], %{})
    :telemetry.execute([:sum], %{count: 5})
    :telemetry.execute([:gauge], %{value: 10})
    :telemetry.execute([:dist], %{value: 15})

    assert Peep.get_metric(name, counter, tags) == 1
    assert Peep.get_metric(name, sum, tags) == 5
    assert Peep.get_metric(name, last_value, tags) == 10
    assert Peep.get_metric(name, distribution, tags).sum == 15
  end

  test "Peep process name can be used with Peep.Storage" do
    name = :"#{__MODULE__}_storage"

    options = [
      name: name,
      metrics: [
        Metrics.counter("another.peep.counter", event_name: [:another, :counter]),
        Metrics.sum("another.peep.sum", event_name: [:another, :sum], measurement: :count)
      ]
    ]

    {:ok, _pid} = Peep.start_link(options)

    :telemetry.execute([:another, :counter], %{})
    :telemetry.execute([:another, :sum], %{count: 10})
    assert %{} = Peep.get_all_metrics(name)
  end

  test "Summary metrics are dropped" do
    name = :"#{__MODULE__}_unsupported"

    options = [
      name: name,
      metrics: [
        Metrics.summary("peep.summary"),
        Metrics.summary("another.peep.summary")
      ]
    ]

    logs =
      capture_log(fn ->
        {:ok, _pid} = Peep.start_link(options)
      end)

    assert %{} == Peep.get_all_metrics(name)

    for event_name <- [[:peep, :summary], [:another, :peep, :summary]] do
      assert String.contains?(logs, "Dropping #{inspect(event_name)}")
    end
  end

  test "Handlers are detached on shutdown" do
    prefix = [:peep, :shutdown_test]

    metric =
      Metrics.counter(prefix ++ [:counter])

    {:ok, options} =
      [
        name: :"#{__MODULE__}_shutdown_test",
        metrics: [metric]
      ]
      |> Peep.Options.validate()

    {:ok, pid} = GenServer.start(Peep, options, name: options.name)

    assert length(:telemetry.list_handlers(prefix)) == 1

    GenServer.stop(pid, :shutdown)

    assert [] == :telemetry.list_handlers(prefix)
  end

  test "Non-numeric values are dropped" do
    name = :"#{__MODULE__}_non_numeric_values"

    sum = Metrics.sum("#{name}.sum", event_name: [name, :sum], measurement: :value)

    last_value =
      Metrics.last_value("#{name}.last_value",
        event_name: [name, :last_value],
        measurement: :value
      )

    dist =
      Metrics.distribution(
        "#{name}.dist",
        event_name: [name, :dist],
        measurement: :value
      )

    metrics = [sum, last_value, dist]

    options = [
      name: name,
      metrics: metrics
    ]

    {:ok, _pid} = Peep.start_link(options)

    :telemetry.execute([name, :sum], %{value: :foo})
    :telemetry.execute([name, :last_value], %{value: "bar"})
    :telemetry.execute([name, :dist], %{value: []})

    assert Peep.get_metric(name, sum, []) == 0
    assert Peep.get_metric(name, last_value, []) == nil
    assert Peep.get_metric(name, dist, []) == nil
  end
end
