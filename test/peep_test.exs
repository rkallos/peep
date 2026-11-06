defmodule PeepTest do
  use ExUnit.Case, async: true
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

    tags = %{foo: "bar", baz: "quux", service: "my-app", env: "production"}
    tag_keys = [:foo, :baz]

    counter = Metrics.counter("peep.counter", event_name: [name, :counter], tags: tag_keys)
    sum = Metrics.sum("peep.sum", event_name: [name, :sum], measurement: :count, tags: tag_keys)

    last_value =
      Metrics.last_value("peep.gauge",
        event_name: [name, :gauge],
        measurement: :value,
        tags: tag_keys
      )

    distribution =
      Metrics.distribution("peep.dist",
        event_name: [name, :dist],
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
    :telemetry.execute([name, :counter], %{})
    :telemetry.execute([name, :sum], %{count: 5})
    :telemetry.execute([name, :gauge], %{value: 10})
    :telemetry.execute([name, :dist], %{value: 15})

    assert Peep.get_all_metrics(name) == %{
             counter => %{tags => 1},
             sum => %{tags => 5},
             last_value => %{tags => 10},
             distribution => %{tags => Peep.Test.distribution_series(distribution, [15])}
           }
  end

  test "event metadata overrides a global tag" do
    name = :"#{__MODULE__}_global_tags_override"
    counter = Metrics.counter("peep.counter", event_name: [name, :counter], tags: [:foo, :baz])

    {:ok, _pid} = Peep.start_link(name: name, metrics: [counter], global_tags: %{foo: :bar})

    :telemetry.execute([name, :counter], %{}, %{foo: 2137, baz: "quux"})

    assert Peep.get_all_metrics(name) == %{counter => %{%{foo: 2137, baz: "quux"} => 1}}
  end

  test "Peep process name can be used with Peep.Storage" do
    name = :"#{__MODULE__}_storage"

    counter = Metrics.counter("another.peep.counter", event_name: [name, :counter])
    sum = Metrics.sum("another.peep.sum", event_name: [name, :sum], measurement: :count)

    {:ok, _pid} = Peep.start_link(name: name, metrics: [counter, sum])

    :telemetry.execute([name, :counter], %{})
    :telemetry.execute([name, :sum], %{count: 10})

    assert Peep.get_all_metrics(name) == %{counter => %{%{} => 1}, sum => %{%{} => 10}}
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
    prefix = [:"#{__MODULE__}_shutdown_test"]

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

  test "persistent_term is cleaned up on shutdown" do
    name = :"#{__MODULE__}_persistent_term_cleanup"

    {:ok, options} =
      Peep.Options.validate(name: name, metrics: [Metrics.counter("cleanup.test.counter")])

    {:ok, pid} = GenServer.start(Peep, options, name: options.name)

    assert Peep.Persistent.fetch(name) != nil

    GenServer.stop(pid, :shutdown)

    assert Peep.Persistent.fetch(name) == nil
  end

  test "metrics with a keep are only recorded for matching events" do
    name = :"#{__MODULE__}_keep"
    keep = fn metadata -> metadata[:kept] == true end

    metrics = [counter, sum, gauge, unfiltered] = keep_metrics(name, keep)

    {:ok, _pid} = Peep.start_link(name: name, metrics: metrics)

    :telemetry.execute([name, :event], %{value: 10}, %{kept: true})
    :telemetry.execute([name, :event], %{value: 99}, %{kept: false})

    assert Peep.get_all_metrics(name) == %{
             counter => %{%{} => 1},
             sum => %{%{} => 10},
             gauge => %{%{} => 10},
             unfiltered => %{%{} => 2}
           }
  end

  test "a 2-arity keep is passed the event's measurements" do
    name = :"#{__MODULE__}_keep_measurements"
    parent = self()

    keep = fn metadata, measurements ->
      send(parent, {:keep, metadata, measurements})
      measurements[:value] == 10
    end

    metrics = [counter, sum, gauge, unfiltered] = keep_metrics(name, keep)

    {:ok, _pid} = Peep.start_link(name: name, metrics: metrics)

    :telemetry.execute([name, :event], %{value: 10}, %{kept: true})
    :telemetry.execute([name, :event], %{value: 99}, %{kept: true})

    assert_received {:keep, %{kept: true}, %{value: 10}}
    assert_received {:keep, %{kept: true}, %{value: 99}}

    assert Peep.get_all_metrics(name) == %{
             counter => %{%{} => 1},
             sum => %{%{} => 10},
             gauge => %{%{} => 10},
             unfiltered => %{%{} => 2}
           }
  end

  test "tag keys absent from metadata are omitted" do
    name = :"#{__MODULE__}_missing_tag_keys"

    one = Metrics.counter("#{name}.one", event_name: [name, :one], tags: [:a])
    two = Metrics.counter("#{name}.two", event_name: [name, :two], tags: [:a, :b])

    {:ok, _pid} = Peep.start_link(name: name, metrics: [one, two])

    :telemetry.execute([name, :one], %{}, %{a: 1})
    :telemetry.execute([name, :one], %{}, %{b: 2})

    :telemetry.execute([name, :two], %{}, %{a: 1, b: 2})
    :telemetry.execute([name, :two], %{}, %{a: 1})

    assert Peep.get_all_metrics(name) == %{
             one => %{%{a: 1} => 1, %{} => 1},
             two => %{%{a: 1, b: 2} => 1, %{a: 1} => 1}
           }
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

    assert Peep.get_all_metrics(name) == %{}
  end

  # A counter, sum and last_value sharing one event and one keep filter, plus an
  # unfiltered counter on the same event to prove only the filtered metrics are
  # skipped.
  defp keep_metrics(name, keep) do
    event = [name, :event]

    [
      Metrics.counter("#{name}.counter", event_name: event, keep: keep),
      Metrics.sum("#{name}.sum", event_name: event, measurement: :value, keep: keep),
      Metrics.last_value("#{name}.gauge", event_name: event, measurement: :value, keep: keep),
      Metrics.counter("#{name}.unfiltered", event_name: event)
    ]
  end
end
