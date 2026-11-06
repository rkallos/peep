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
    tags = %{foo: "bar", baz: "quux", service: "my-app", env: "production"}
    tag_keys = [:foo, :baz]
    [counter_event, sum_event, gauge_event, dist_event] = [event(), event(), event(), event()]

    counter = Metrics.counter("peep.counter", event_name: counter_event, tags: tag_keys)
    sum = Metrics.sum("peep.sum", event_name: sum_event, measurement: :count, tags: tag_keys)

    last_value =
      Metrics.last_value("peep.gauge",
        event_name: gauge_event,
        measurement: :value,
        tags: tag_keys
      )

    dist =
      Metrics.distribution("peep.dist",
        event_name: dist_event,
        measurement: :value,
        tags: tag_keys,
        reporter_options: [max_value: 100]
      )

    check(
      metrics: [counter, sum, last_value, dist],
      global_tags: tags,
      events: [
        {counter_event, %{}, %{}},
        {sum_event, %{count: 5}, %{}},
        {gauge_event, %{value: 10}, %{}},
        {dist_event, %{value: 15}, %{}}
      ],
      exp_scrape: %{
        counter => %{tags => 1},
        sum => %{tags => 5},
        last_value => %{tags => 10},
        dist => %{tags => Peep.Test.distribution_series(dist, [15])}
      }
    )
  end

  test "event metadata overrides a global tag" do
    event = event()
    counter = Metrics.counter("peep.counter", event_name: event, tags: [:foo, :baz])

    check(
      metrics: [counter],
      global_tags: %{foo: :bar},
      events: [{event, %{}, %{foo: 2137, baz: "quux"}}],
      exp_scrape: %{counter => %{%{foo: 2137, baz: "quux"} => 1}}
    )
  end

  test "Peep process name can be used with Peep.Storage" do
    [counter_event, sum_event] = [event(), event()]
    counter = Metrics.counter("another.peep.counter", event_name: counter_event)
    sum = Metrics.sum("another.peep.sum", event_name: sum_event, measurement: :count)

    check(
      metrics: [counter, sum],
      events: [{counter_event, %{}, %{}}, {sum_event, %{count: 10}, %{}}],
      exp_scrape: %{counter => %{%{} => 1}, sum => %{%{} => 10}}
    )
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
    event = event()
    keep = fn metadata -> metadata[:kept] == true end
    metrics = [counter, sum, gauge, unfiltered] = keep_metrics(event, keep)

    check(
      metrics: metrics,
      events: [{event, %{value: 10}, %{kept: true}}, {event, %{value: 99}, %{kept: false}}],
      exp_scrape: %{
        counter => %{%{} => 1},
        sum => %{%{} => 10},
        gauge => %{%{} => 10},
        unfiltered => %{%{} => 2}
      }
    )
  end

  test "a 2-arity keep is passed the event's measurements" do
    event = event()
    parent = self()

    keep = fn metadata, measurements ->
      send(parent, {:keep, metadata, measurements})
      measurements[:value] == 10
    end

    metrics = [counter, sum, gauge, unfiltered] = keep_metrics(event, keep)

    check(
      metrics: metrics,
      events: [{event, %{value: 10}, %{kept: true}}, {event, %{value: 99}, %{kept: true}}],
      exp_scrape: %{
        counter => %{%{} => 1},
        sum => %{%{} => 10},
        gauge => %{%{} => 10},
        unfiltered => %{%{} => 2}
      }
    )

    assert_received {:keep, %{kept: true}, %{value: 10}}
    assert_received {:keep, %{kept: true}, %{value: 99}}
  end

  test "tag keys absent from metadata are omitted" do
    [one_event, two_event] = [event(), event()]
    one = Metrics.counter("peep.one", event_name: one_event, tags: [:a])
    two = Metrics.counter("peep.two", event_name: two_event, tags: [:a, :b])

    check(
      metrics: [one, two],
      events: [
        {one_event, %{}, %{a: 1}},
        {one_event, %{}, %{b: 2}},
        {two_event, %{}, %{a: 1, b: 2}},
        {two_event, %{}, %{a: 1}}
      ],
      exp_scrape: %{
        one => %{%{a: 1} => 1, %{} => 1},
        two => %{%{a: 1, b: 2} => 1, %{a: 1} => 1}
      }
    )
  end

  test "Non-numeric values are dropped" do
    [sum_event, gauge_event, dist_event] = [event(), event(), event()]
    sum = Metrics.sum("peep.sum", event_name: sum_event, measurement: :value)
    last_value = Metrics.last_value("peep.gauge", event_name: gauge_event, measurement: :value)
    dist = Metrics.distribution("peep.dist", event_name: dist_event, measurement: :value)

    check(
      metrics: [sum, last_value, dist],
      events: [
        {sum_event, %{value: :foo}, %{}},
        {gauge_event, %{value: "bar"}, %{}},
        {dist_event, %{value: []}, %{}}
      ],
      exp_scrape: %{}
    )
  end

  defp keep_metrics(event, keep) do
    [
      Metrics.counter("peep.counter", event_name: event, keep: keep),
      Metrics.sum("peep.sum", event_name: event, measurement: :value, keep: keep),
      Metrics.last_value("peep.gauge", event_name: event, measurement: :value, keep: keep),
      Metrics.counter("peep.unfiltered", event_name: event)
    ]
  end

  defp check(opts) do
    name =
      Peep.Test.start_peep!(
        metrics: Keyword.fetch!(opts, :metrics),
        global_tags: Keyword.get(opts, :global_tags, %{})
      )

    for {event, measurements, metadata} <- Keyword.get(opts, :events, []) do
      :telemetry.execute(event, measurements, metadata)
    end

    assert Peep.get_all_metrics(name) == Keyword.fetch!(opts, :exp_scrape)
  end

  defp event, do: [Peep.Test.fresh_id()]
end
