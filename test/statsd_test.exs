defmodule StatsdTest do
  use ExUnit.Case, async: true

  alias Peep.Statsd
  alias Peep.Statsd.Cache
  alias Telemetry.Metrics

  test "a worker with statsd options sends its metrics over UDP" do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    event = [Peep.Test.fresh_id()]
    counter = Metrics.counter("statsd.test.counter", event_name: event)

    Peep.Test.start_peep!(
      metrics: [counter],
      statsd: [host: "127.0.0.1", port: port, flush_interval_ms: 10]
    )

    :telemetry.execute(event, %{})

    assert_receive {:udp, ^socket, _address, _port, "statsd.test.counter:1|c\n"}
    refute_receive {:udp, ^socket, _address, _port, _packet}, 100
  end

  test "a counter can be formatted" do
    counter = Metrics.counter("statsd.test.counter")

    check(
      scrape: %{counter => %{%{} => 10, %{even: true} => 5}},
      exp_lines: ["statsd.test.counter:10|c", "statsd.test.counter:5|c|#even:true"]
    )
  end

  test "a sum can be formatted" do
    sum = Metrics.sum("statsd.test.sum")

    check(
      scrape: %{sum => %{%{} => 10, %{even: true} => 5}},
      exp_lines: ["statsd.test.sum:10|c", "statsd.test.sum:5|c|#even:true"]
    )
  end

  test "a last_value can be formatted" do
    last_value = Metrics.last_value("statsd.test.gauge")

    check(
      scrape: %{last_value => %{%{} => 10, %{odd: true} => 9}},
      exp_lines: ["statsd.test.gauge:10|g", "statsd.test.gauge:9|g|#odd:true"]
    )
  end

  test "a distribution can be formatted (standard)" do
    dist = Metrics.distribution("statsd.test.dist", reporter_options: [max_value: 1000])

    check(
      scrape: %{
        dist => %{
          %{} => Peep.Test.distribution_series(dist, 1..1000),
          %{foo: :bar} => Peep.Test.distribution_series(dist, 100..1000//100)
        }
      },
      formatter: :standard,
      exp_lines: [
        "statsd.test.dist:1.0|ms|@1.0",
        "statsd.test.dist:2.23152|ms|@1.0",
        "statsd.test.dist:3.333505|ms|@1.0",
        "statsd.test.dist:4.074283|ms|@1.0",
        "statsd.test.dist:6.086275|ms|@0.5",
        "statsd.test.dist:7.438781|ms|@1.0",
        "statsd.test.dist:9.091843|ms|@0.5",
        "statsd.test.dist:11.112253|ms|@0.5",
        "statsd.test.dist:13.581642|ms|@0.5",
        "statsd.test.dist:16.599785|ms|@0.333333",
        "statsd.test.dist:20.288626|ms|@0.25",
        "statsd.test.dist:24.79721|ms|@0.25",
        "statsd.test.dist:30.307701|ms|@0.166667",
        "statsd.test.dist:37.042745|ms|@0.142857",
        "statsd.test.dist:45.274466|ms|@0.125",
        "statsd.test.dist:55.335459|ms|@0.1",
        "statsd.test.dist:67.632227|ms|@0.083333",
        "statsd.test.dist:82.661611|ms|@0.066667",
        "statsd.test.dist:101.030858|ms|@0.052632",
        "statsd.test.dist:123.48216|ms|@0.045455",
        "statsd.test.dist:150.92264|ms|@0.037037",
        "statsd.test.dist:184.461004|ms|@0.029412",
        "statsd.test.dist:225.452339|ms|@0.02439",
        "statsd.test.dist:275.552858|ms|@0.02",
        "statsd.test.dist:336.786827|ms|@0.016393",
        "statsd.test.dist:411.628344|ms|@0.013333",
        "statsd.test.dist:503.101309|ms|@0.01087",
        "statsd.test.dist:614.9016|ms|@0.009009",
        "statsd.test.dist:751.5464|ms|@0.007299",
        "statsd.test.dist:918.556711|ms|@0.005988",
        "statsd.test.dist:1122.680424|ms|@0.012195",
        "statsd.test.dist:101.030858|ms|@1.0|#foo:bar",
        "statsd.test.dist:225.452339|ms|@1.0|#foo:bar",
        "statsd.test.dist:336.786827|ms|@1.0|#foo:bar",
        "statsd.test.dist:411.628344|ms|@1.0|#foo:bar",
        "statsd.test.dist:503.101309|ms|@1.0|#foo:bar",
        "statsd.test.dist:614.9016|ms|@1.0|#foo:bar",
        "statsd.test.dist:751.5464|ms|@1.0|#foo:bar",
        "statsd.test.dist:918.556711|ms|@0.5|#foo:bar",
        "statsd.test.dist:1122.680424|ms|@1.0|#foo:bar"
      ]
    )
  end

  test "a distribution can be formatted (datadog)" do
    dist = Metrics.distribution("statsd.test.dist", reporter_options: [max_value: 1000])

    check(
      scrape: %{
        dist => %{
          %{} => Peep.Test.distribution_series(dist, 1..1000),
          %{foo: :bar} => Peep.Test.distribution_series(dist, 100..1000//100)
        }
      },
      formatter: :datadog,
      exp_lines: [
        "statsd.test.dist:1.0|d|@1.0",
        "statsd.test.dist:2.23152|d|@1.0",
        "statsd.test.dist:3.333505|d|@1.0",
        "statsd.test.dist:4.074283|d|@1.0",
        "statsd.test.dist:6.086275|d|@0.5",
        "statsd.test.dist:7.438781|d|@1.0",
        "statsd.test.dist:9.091843|d|@0.5",
        "statsd.test.dist:11.112253|d|@0.5",
        "statsd.test.dist:13.581642|d|@0.5",
        "statsd.test.dist:16.599785|d|@0.333333",
        "statsd.test.dist:20.288626|d|@0.25",
        "statsd.test.dist:24.79721|d|@0.25",
        "statsd.test.dist:30.307701|d|@0.166667",
        "statsd.test.dist:37.042745|d|@0.142857",
        "statsd.test.dist:45.274466|d|@0.125",
        "statsd.test.dist:55.335459|d|@0.1",
        "statsd.test.dist:67.632227|d|@0.083333",
        "statsd.test.dist:82.661611|d|@0.066667",
        "statsd.test.dist:101.030858|d|@0.052632",
        "statsd.test.dist:123.48216|d|@0.045455",
        "statsd.test.dist:150.92264|d|@0.037037",
        "statsd.test.dist:184.461004|d|@0.029412",
        "statsd.test.dist:225.452339|d|@0.02439",
        "statsd.test.dist:275.552858|d|@0.02",
        "statsd.test.dist:336.786827|d|@0.016393",
        "statsd.test.dist:411.628344|d|@0.013333",
        "statsd.test.dist:503.101309|d|@0.01087",
        "statsd.test.dist:614.9016|d|@0.009009",
        "statsd.test.dist:751.5464|d|@0.007299",
        "statsd.test.dist:918.556711|d|@0.005988",
        "statsd.test.dist:1122.680424|d|@0.012195",
        "statsd.test.dist:101.030858|d|@1.0|#foo:bar",
        "statsd.test.dist:225.452339|d|@1.0|#foo:bar",
        "statsd.test.dist:336.786827|d|@1.0|#foo:bar",
        "statsd.test.dist:411.628344|d|@1.0|#foo:bar",
        "statsd.test.dist:503.101309|d|@1.0|#foo:bar",
        "statsd.test.dist:614.9016|d|@1.0|#foo:bar",
        "statsd.test.dist:751.5464|d|@1.0|#foo:bar",
        "statsd.test.dist:918.556711|d|@0.5|#foo:bar",
        "statsd.test.dist:1122.680424|d|@1.0|#foo:bar"
      ]
    )
  end

  test "above-max distribution samples are excluded from output" do
    dist = Metrics.distribution("statsd.test.dist", reporter_options: [max_value: 100])

    check(
      scrape: %{dist => %{%{} => Peep.Test.distribution_series(dist, [50, 500, 5000])}},
      exp_lines: ["statsd.test.dist:55.335459|ms|@1.0"]
    )
  end

  test "metrics are batched according to mtu option" do
    scrape =
      for i <- 1..10, into: %{} do
        {Metrics.sum("statsd.test.sum.#{i}"), %{%{} => 55}}
      end

    scrape =
      for i <- 1..10, into: scrape do
        {Metrics.last_value("statsd.test.gauge.#{i}"), %{%{} => 10}}
      end

    exp_lines =
      Enum.map(1..10, &"statsd.test.sum.#{&1}:55|c") ++
        Enum.map(1..10, &"statsd.test.gauge.#{&1}:10|g")

    check(scrape: scrape, mtu: 100, exp_lines: exp_lines)
    check(scrape: scrape, mtu: 200, exp_lines: exp_lines)
  end

  test "nothing is sent when nothing changed since the last flush" do
    counter = Metrics.counter("statsd.test.counter")

    check(
      prev_scrape: %{counter => %{%{} => 10}},
      scrape: %{counter => %{%{} => 10}},
      exp_lines: []
    )
  end

  defp check(opts) do
    scrape = Keyword.fetch!(opts, :scrape)
    formatter = Keyword.get(opts, :formatter, :standard)
    mtu = Keyword.get(opts, :mtu, 1_000_000)
    exp_lines = Keyword.fetch!(opts, :exp_lines)

    state = Statsd.make_state(%{formatter: formatter, mtu: mtu})
    state = %{state | prev: Cache.new(Keyword.get(opts, :prev_scrape, %{}))}
    {_cache, packets} = Statsd.prepare(scrape, state)
    packets = Enum.map(packets, &IO.iodata_to_binary(&1.lines))
    lines = Enum.flat_map(packets, &String.split(&1, "\n", trim: true))

    assert Enum.sort(lines) == Enum.sort(exp_lines)
    assert Enum.all?(packets, &(byte_size(&1) in 1..mtu))
  end
end
