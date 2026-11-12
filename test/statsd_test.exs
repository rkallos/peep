defmodule StatsdTest do
  use ExUnit.Case, async: true

  alias Peep.Statsd
  alias Peep.Statsd.Cache
  alias Peep.Test.UDP
  alias Telemetry.Metrics

  @kilo [peep_export_conversion_factor: 0.001]

  test "a worker with statsd options sends its metrics over UDP" do
    event = event()

    check_sent(
      metrics: [Metrics.counter("statsd.test.counter", event_name: event)],
      events: [{event, %{}, %{}}],
      exp_packets: ["statsd.test.counter:1|c\n"]
    )
  end

  test "a worker flushes by itself every flush interval" do
    event = event()

    check_sent(
      metrics: [Metrics.counter("statsd.test.counter", event_name: event)],
      statsd: [flush_interval_ms: 10],
      flushes: 0,
      events: [{event, %{}, %{}}],
      exp_packets: ["statsd.test.counter:1|c\n"]
    )
  end

  test "flushing a worker without statsd options does nothing" do
    name = Peep.Test.start_peep!(metrics: [])
    assert Peep.statsd_flush(name) == :ok
  end

  test "the host can be an IP address tuple" do
    event = event()

    check_sent(
      metrics: [Metrics.counter("statsd.test.counter", event_name: event)],
      statsd: [host: {127, 0, 0, 1}],
      events: [{event, %{}, %{}}],
      exp_packets: ["statsd.test.counter:1|c\n"]
    )
  end

  test "distributions can be sent in the datadog format" do
    event = event()

    dist =
      Metrics.distribution("statsd.test.dist",
        event_name: event,
        measurement: :value,
        reporter_options: [max_value: 100]
      )

    check_sent(
      metrics: [dist],
      statsd: [formatter: :datadog],
      events: [{event, %{value: 50}, %{}}],
      exp_packets: ["statsd.test.dist:55.335458702837705|d|@1.0\n"]
    )
  end

  test "a worker can send to a Unix domain socket" do
    event = event()

    check_sent(
      unix_socket?: true,
      metrics: [Metrics.counter("statsd.test.counter", event_name: event)],
      events: [{event, %{}, %{}}],
      exp_packets: ["statsd.test.counter:1|c\n"]
    )
  end

  test "a packet that couldn't be sent for now is sent at the next flush" do
    event = event()

    check_sent(
      fail: [send: [{:error, :eagain}]],
      metrics: [Metrics.counter("statsd.test.counter", event_name: event)],
      events: [{event, %{}, %{}}],
      exp_packets: ["statsd.test.counter:1|c\n"],
      exp_packet_errors: [:eagain]
    )
  end

  test "a packet too large to send is split at the next flush" do
    event = event()

    check_sent(
      fail: [send: [{:error, :emsgsize}]],
      metrics: [
        Metrics.counter("statsd.test.a", event_name: event),
        Metrics.counter("statsd.test.b", event_name: event)
      ],
      events: [{event, %{}, %{}}],
      exp_packets: ["statsd.test.a:1|c\n", "statsd.test.b:1|c\n"],
      exp_packet_errors: [:emsgsize]
    )
  end

  test "a packet that failed to send is resent at the next flush" do
    event = event()

    check_sent(
      fail: [send: [{:error, :econnrefused}]],
      metrics: [Metrics.counter("statsd.test.counter", event_name: event)],
      events: [{event, %{}, %{}}],
      exp_packets: ["statsd.test.counter:1|c\n"],
      exp_packet_errors: [:econnrefused]
    )
  end

  @tag capture_log: true
  test "a socket that couldn't be opened is opened at the next flush" do
    event = event()

    check_sent(
      fail: [open: [{:error, :emfile}]],
      metrics: [Metrics.counter("statsd.test.counter", event_name: event)],
      events: [{event, %{}, %{}}],
      exp_packets: ["statsd.test.counter:1|c\n"]
    )
  end

  test "invalid statsd options are rejected" do
    check_rejected(
      [host: :nope],
      "invalid value for :host option: expected :host to be an IP address or a hostname, got :nope"
    )

    check_rejected(
      [host: {999, 0, 0, 1}],
      "invalid value for :host option: expected :host to be a valid IP address, got {999, 0, 0, 1}"
    )

    check_rejected(
      [socket_path: 1],
      "invalid value for :socket_path option: expected :socket_path to be a string, got 1"
    )

    check_rejected(
      [formatter: :nope],
      "invalid value for :formatter option: expected :formatter be either :standard or :datadog, got :nope"
    )
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

  test "float values are formatted with at most two decimals" do
    last_value = Metrics.last_value("statsd.test.gauge")
    sum = Metrics.sum("statsd.test.sum")

    check(
      scrape: %{last_value => %{%{} => 1.234}, sum => %{%{} => 2.5}},
      exp_lines: ["statsd.test.gauge:1.23|g", "statsd.test.sum:2.5|c"]
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
        "statsd.test.dist:2.231519585429051|ms|@1.0",
        "statsd.test.dist:3.3335045658878424|ms|@1.0",
        "statsd.test.dist:4.074283358307364|ms|@1.0",
        "statsd.test.dist:6.086275140187544|ms|@0.5",
        "statsd.test.dist:7.438780726895887|ms|@1.0",
        "statsd.test.dist:9.09184311065053|ms|@0.5",
        "statsd.test.dist:11.112252690795092|ms|@0.5",
        "statsd.test.dist:13.581642177638448|ms|@0.5",
        "statsd.test.dist:16.599784883780327|ms|@0.333333",
        "statsd.test.dist:20.288625969064846|ms|@0.25",
        "statsd.test.dist:24.797209517745923|ms|@0.25",
        "statsd.test.dist:30.307700521689465|ms|@0.166667",
        "statsd.test.dist:37.042745082064904|ms|@0.142857",
        "statsd.test.dist:45.274466211412665|ms|@0.125",
        "statsd.test.dist:55.335458702837705|ms|@0.1",
        "statsd.test.dist:67.63222730346831|ms|@0.083333",
        "statsd.test.dist:82.6616111486835|ms|@0.066667",
        "statsd.test.dist:101.03085807061318|ms|@0.052632",
        "statsd.test.dist:123.48215986408277|ms|@0.045455",
        "statsd.test.dist:150.92263983387897|ms|@0.037037",
        "statsd.test.dist:184.46100424140764|ms|@0.029412",
        "statsd.test.dist:225.45233851727602|ms|@0.02439",
        "statsd.test.dist:275.5528581877818|ms|@0.02",
        "statsd.test.dist:336.7868266739556|ms|@0.016393",
        "statsd.test.dist:411.62834371261243|ms|@0.013333",
        "statsd.test.dist:503.1013089820819|ms|@0.01087",
        "statsd.test.dist:614.901599866989|ms|@0.009009",
        "statsd.test.dist:751.5463998374311|ms|@0.007299",
        "statsd.test.dist:918.5567109124158|ms|@0.005988",
        "statsd.test.dist:1122.6804244485083|ms|@0.012195",
        "statsd.test.dist:101.03085807061318|ms|@1.0|#foo:bar",
        "statsd.test.dist:225.45233851727602|ms|@1.0|#foo:bar",
        "statsd.test.dist:336.7868266739556|ms|@1.0|#foo:bar",
        "statsd.test.dist:411.62834371261243|ms|@1.0|#foo:bar",
        "statsd.test.dist:503.1013089820819|ms|@1.0|#foo:bar",
        "statsd.test.dist:614.901599866989|ms|@1.0|#foo:bar",
        "statsd.test.dist:751.5463998374311|ms|@1.0|#foo:bar",
        "statsd.test.dist:918.5567109124158|ms|@0.5|#foo:bar",
        "statsd.test.dist:1122.6804244485083|ms|@1.0|#foo:bar"
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
        "statsd.test.dist:2.231519585429051|d|@1.0",
        "statsd.test.dist:3.3335045658878424|d|@1.0",
        "statsd.test.dist:4.074283358307364|d|@1.0",
        "statsd.test.dist:6.086275140187544|d|@0.5",
        "statsd.test.dist:7.438780726895887|d|@1.0",
        "statsd.test.dist:9.09184311065053|d|@0.5",
        "statsd.test.dist:11.112252690795092|d|@0.5",
        "statsd.test.dist:13.581642177638448|d|@0.5",
        "statsd.test.dist:16.599784883780327|d|@0.333333",
        "statsd.test.dist:20.288625969064846|d|@0.25",
        "statsd.test.dist:24.797209517745923|d|@0.25",
        "statsd.test.dist:30.307700521689465|d|@0.166667",
        "statsd.test.dist:37.042745082064904|d|@0.142857",
        "statsd.test.dist:45.274466211412665|d|@0.125",
        "statsd.test.dist:55.335458702837705|d|@0.1",
        "statsd.test.dist:67.63222730346831|d|@0.083333",
        "statsd.test.dist:82.6616111486835|d|@0.066667",
        "statsd.test.dist:101.03085807061318|d|@0.052632",
        "statsd.test.dist:123.48215986408277|d|@0.045455",
        "statsd.test.dist:150.92263983387897|d|@0.037037",
        "statsd.test.dist:184.46100424140764|d|@0.029412",
        "statsd.test.dist:225.45233851727602|d|@0.02439",
        "statsd.test.dist:275.5528581877818|d|@0.02",
        "statsd.test.dist:336.7868266739556|d|@0.016393",
        "statsd.test.dist:411.62834371261243|d|@0.013333",
        "statsd.test.dist:503.1013089820819|d|@0.01087",
        "statsd.test.dist:614.901599866989|d|@0.009009",
        "statsd.test.dist:751.5463998374311|d|@0.007299",
        "statsd.test.dist:918.5567109124158|d|@0.005988",
        "statsd.test.dist:1122.6804244485083|d|@0.012195",
        "statsd.test.dist:101.03085807061318|d|@1.0|#foo:bar",
        "statsd.test.dist:225.45233851727602|d|@1.0|#foo:bar",
        "statsd.test.dist:336.7868266739556|d|@1.0|#foo:bar",
        "statsd.test.dist:411.62834371261243|d|@1.0|#foo:bar",
        "statsd.test.dist:503.1013089820819|d|@1.0|#foo:bar",
        "statsd.test.dist:614.901599866989|d|@1.0|#foo:bar",
        "statsd.test.dist:751.5463998374311|d|@1.0|#foo:bar",
        "statsd.test.dist:918.5567109124158|d|@0.5|#foo:bar",
        "statsd.test.dist:1122.6804244485083|d|@1.0|#foo:bar"
      ]
    )
  end

  describe "peep_export_conversion_factor" do
    test "converts what was added to a sum since the last flush" do
      sum = Metrics.sum("statsd.test.sum", reporter_options: @kilo)

      check(
        prev_scrape: %{sum => %{%{} => 1000}},
        scrape: %{sum => %{%{} => 4500}},
        exp_lines: ["statsd.test.sum:3.5|c"]
      )
    end

    test "converts a last_value" do
      last_value = Metrics.last_value("statsd.test.gauge", reporter_options: @kilo)

      check(
        scrape: %{last_value => %{%{} => 1500}},
        exp_lines: ["statsd.test.gauge:1.5|g"]
      )
    end

    test "converts a distribution's bucket bounds" do
      dist = Metrics.distribution("statsd.test.dist", reporter_options: @kilo)

      check(
        scrape: %{dist => %{%{} => %{1000.0 => 1, 2000.0 => 2, infinity: 1, sum: 7500}}},
        exp_lines: ["statsd.test.dist:1.0|ms|@1.0", "statsd.test.dist:2.0|ms|@0.5"]
      )
    end

    test "does not convert a counter" do
      counter = Metrics.counter("statsd.test.counter", reporter_options: @kilo)

      check(
        scrape: %{counter => %{%{} => 3000}},
        exp_lines: ["statsd.test.counter:3000|c"]
      )
    end
  end

  test "above-max distribution samples are excluded from output" do
    dist = Metrics.distribution("statsd.test.dist", reporter_options: [max_value: 100])

    check(
      scrape: %{dist => %{%{} => Peep.Test.distribution_series(dist, [50, 500, 5000])}},
      exp_lines: ["statsd.test.dist:55.335458702837705|ms|@1.0"]
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

  def handle_packet_error(_event, _measurements, %{reason: reason}, pid) do
    send(pid, {:packet_error, reason})
  end

  # Starts a reporter sending to a socket of its own, emits the events, and
  # flushes once, plus once more for every failure queued with :fail.
  defp check_sent(opts) do
    for {fun, results} <- Keyword.get(opts, :fail, []), do: UDP.fail(fun, results)

    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:peep, :packet, :error],
        &__MODULE__.handle_packet_error/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {socket, statsd} = open_receiver(Keyword.get(opts, :unix_socket?, false))

    name =
      Peep.Test.start_peep!(
        metrics: Keyword.fetch!(opts, :metrics),
        statsd:
          Keyword.merge(
            statsd ++ [flush_interval_ms: :timer.hours(1)],
            Keyword.get(opts, :statsd, [])
          )
      )

    for {event, measurements, metadata} <- Keyword.fetch!(opts, :events) do
      :telemetry.execute(event, measurements, metadata)
    end

    failures = opts |> Keyword.get(:fail, []) |> Keyword.values() |> Enum.concat()
    for _ <- 1..Keyword.get(opts, :flushes, 1 + length(failures))//1, do: Peep.statsd_flush(name)

    exp_packets = Keyword.fetch!(opts, :exp_packets)
    assert Enum.sort(receive_packets(socket, length(exp_packets))) == Enum.sort(exp_packets)
    assert receive_packet_errors() == Keyword.get(opts, :exp_packet_errors, [])
  end

  defp open_receiver(false = _unix_socket?) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    {socket, [host: "127.0.0.1", port: port]}
  end

  defp open_receiver(true = _unix_socket?) do
    path = Path.join(System.tmp_dir!(), "peep-#{System.unique_integer([:positive])}.sock")
    on_exit(fn -> File.rm(path) end)
    {:ok, socket} = :gen_udp.open(0, [:binary, :local, active: true, ifaddr: {:local, path}])
    {socket, [socket_path: path]}
  end

  # Waits for `count` packets, then briefly for any that shouldn't follow.
  defp receive_packets(socket, count) do
    timeout = if count > 0, do: 1_000, else: 10

    receive do
      {:udp, ^socket, _address, _port, packet} -> [packet | receive_packets(socket, count - 1)]
    after
      timeout -> []
    end
  end

  defp receive_packet_errors do
    receive do
      {:packet_error, reason} -> [reason | receive_packet_errors()]
    after
      0 -> []
    end
  end

  defp event, do: [Peep.Test.fresh_id()]

  defp check_rejected(statsd_opts, exp_reason) do
    assert Peep.start_link(name: Peep.Test.fresh_id(), metrics: [], statsd: statsd_opts) ==
             {:error,
              "expected :statsd option to match at least one given type, but didn't match any. " <>
                "Here are the reasons why it didn't match each of the allowed types:\n\n" <>
                "  * #{exp_reason} (in options [:statsd])\n" <>
                "  * invalid value for :statsd option: expected nil, got: #{inspect(statsd_opts)}"}
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
