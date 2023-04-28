defmodule StatsdTest do
  use ExUnit.Case

  alias Peep.{Statsd, Storage}
  alias Telemetry.Metrics

  alias Peep.Support.StorageCounter

  test "a counter can be formatted" do
    tid = Storage.new(StorageCounter.fresh_id())

    counter = Metrics.counter("storage.test.counter")

    for i <- 1..10 do
      Storage.insert_metric(tid, counter, 1, [])

      if rem(i, 2) == 0 do
        Storage.insert_metric(tid, counter, 1, even: true)
      end
    end

    expected = ["storage.test.counter:10|c", "storage.test.counter:5|c|#even:true"]
    assert parse_packets(get_statsd_packets(tid)) == parse_packets(expected)
  end

  test "a last_value can be formatted" do
    tid = Storage.new(StorageCounter.fresh_id())

    last_value = Metrics.last_value("storage.test.gauge")

    for i <- 1..10 do
      Storage.insert_metric(tid, last_value, i, [])

      if rem(i, 2) == 1 do
        Storage.insert_metric(tid, last_value, i, odd: true)
      end
    end

    expected = ["storage.test.gauge:10|g", "storage.test.gauge:9|g|#odd:true"]
    assert parse_packets(get_statsd_packets(tid)) == parse_packets(expected)
  end

  test "a distribution can be formatted (standard)" do
    tid = Storage.new(StorageCounter.fresh_id())

    dist = Metrics.distribution("storage.test.dist")

    for i <- 1..1000 do
      Storage.insert_metric(tid, dist, i, [])

      if rem(i, 100) == 0 do
        Storage.insert_metric(tid, dist, i, foo: :bar)
      end
    end

    expected = [
      "storage.test.dist:1.0|ms|@1.0",
      "storage.test.dist:2.23152|ms|@1.0",
      "storage.test.dist:3.333505|ms|@1.0",
      "storage.test.dist:4.074283|ms|@1.0",
      "storage.test.dist:6.086275|ms|@0.5",
      "storage.test.dist:7.438781|ms|@1.0",
      "storage.test.dist:9.091843|ms|@0.5",
      "storage.test.dist:11.112253|ms|@0.5",
      "storage.test.dist:13.581642|ms|@0.5",
      "storage.test.dist:16.599785|ms|@0.333333",
      "storage.test.dist:20.288626|ms|@0.25",
      "storage.test.dist:24.79721|ms|@0.25",
      "storage.test.dist:30.307701|ms|@0.166667",
      "storage.test.dist:37.042745|ms|@0.142857",
      "storage.test.dist:45.274466|ms|@0.125",
      "storage.test.dist:55.335459|ms|@0.1",
      "storage.test.dist:67.632227|ms|@0.083333",
      "storage.test.dist:82.661611|ms|@0.066667",
      "storage.test.dist:101.030858|ms|@0.052632",
      "storage.test.dist:123.48216|ms|@0.045455",
      "storage.test.dist:150.92264|ms|@0.037037",
      "storage.test.dist:184.461004|ms|@0.029412",
      "storage.test.dist:225.452339|ms|@0.02439",
      "storage.test.dist:275.552858|ms|@0.02",
      "storage.test.dist:336.786827|ms|@0.016393",
      "storage.test.dist:411.628344|ms|@0.013333",
      "storage.test.dist:503.101309|ms|@0.01087",
      "storage.test.dist:614.9016|ms|@0.009009",
      "storage.test.dist:751.5464|ms|@0.007299",
      "storage.test.dist:918.556711|ms|@0.005988",
      "storage.test.dist:1122.680424|ms|@0.012195",
      #
      "storage.test.dist:101.030858|ms|@1.0|#foo:bar",
      "storage.test.dist:225.452339|ms|@1.0|#foo:bar",
      "storage.test.dist:336.786827|ms|@1.0|#foo:bar",
      "storage.test.dist:411.628344|ms|@1.0|#foo:bar",
      "storage.test.dist:503.101309|ms|@1.0|#foo:bar",
      "storage.test.dist:614.9016|ms|@1.0|#foo:bar",
      "storage.test.dist:751.5464|ms|@1.0|#foo:bar",
      "storage.test.dist:918.556711|ms|@0.5|#foo:bar",
      "storage.test.dist:1122.680424|ms|@1.0|#foo:bar"
    ]

    packets = get_statsd_packets(tid, %{formatter: :standard})

    assert parse_packets(packets) == parse_packets(expected)
  end

  test "a distribution can be formatted (datadog)" do
    tid = Storage.new(StorageCounter.fresh_id())

    dist = Metrics.distribution("storage.test.dist")

    for i <- 1..1000 do
      Storage.insert_metric(tid, dist, i, [])

      if rem(i, 100) == 0 do
        Storage.insert_metric(tid, dist, i, foo: :bar)
      end
    end

    expected = [
      "storage.test.dist:1.0|d|@1.0",
      "storage.test.dist:2.23152|d|@1.0",
      "storage.test.dist:3.333505|d|@1.0",
      "storage.test.dist:4.074283|d|@1.0",
      "storage.test.dist:6.086275|d|@0.5",
      "storage.test.dist:7.438781|d|@1.0",
      "storage.test.dist:9.091843|d|@0.5",
      "storage.test.dist:11.112253|d|@0.5",
      "storage.test.dist:13.581642|d|@0.5",
      "storage.test.dist:16.599785|d|@0.333333",
      "storage.test.dist:20.288626|d|@0.25",
      "storage.test.dist:24.79721|d|@0.25",
      "storage.test.dist:30.307701|d|@0.166667",
      "storage.test.dist:37.042745|d|@0.142857",
      "storage.test.dist:45.274466|d|@0.125",
      "storage.test.dist:55.335459|d|@0.1",
      "storage.test.dist:67.632227|d|@0.083333",
      "storage.test.dist:82.661611|d|@0.066667",
      "storage.test.dist:101.030858|d|@0.052632",
      "storage.test.dist:123.48216|d|@0.045455",
      "storage.test.dist:150.92264|d|@0.037037",
      "storage.test.dist:184.461004|d|@0.029412",
      "storage.test.dist:225.452339|d|@0.02439",
      "storage.test.dist:275.552858|d|@0.02",
      "storage.test.dist:336.786827|d|@0.016393",
      "storage.test.dist:411.628344|d|@0.013333",
      "storage.test.dist:503.101309|d|@0.01087",
      "storage.test.dist:614.9016|d|@0.009009",
      "storage.test.dist:751.5464|d|@0.007299",
      "storage.test.dist:918.556711|d|@0.005988",
      "storage.test.dist:1122.680424|d|@0.012195",
      #
      "storage.test.dist:101.030858|d|@1.0|#foo:bar",
      "storage.test.dist:225.452339|d|@1.0|#foo:bar",
      "storage.test.dist:336.786827|d|@1.0|#foo:bar",
      "storage.test.dist:411.628344|d|@1.0|#foo:bar",
      "storage.test.dist:503.101309|d|@1.0|#foo:bar",
      "storage.test.dist:614.9016|d|@1.0|#foo:bar",
      "storage.test.dist:751.5464|d|@1.0|#foo:bar",
      "storage.test.dist:918.556711|d|@0.5|#foo:bar",
      "storage.test.dist:1122.680424|d|@1.0|#foo:bar"
    ]

    packets = get_statsd_packets(tid, %{formatter: :datadog})
    assert parse_packets(packets) == parse_packets(expected)
  end

  test "metrics are batched according to mtu option" do
    tid = Storage.new(StorageCounter.fresh_id())

    for i <- 1..10 do
      counter = Metrics.counter("storage.test.counter.#{i}")
      last_value = Metrics.last_value("storage.test.gauge.#{i}")

      for j <- 1..10 do
        Storage.insert_metric(tid, counter, j, [])
        Storage.insert_metric(tid, last_value, j, [])
      end
    end

    expected_metrics =
      [
        "storage.test.counter.5:55|c",
        "storage.test.counter.4:55|c",
        "storage.test.counter.3:55|c",
        "storage.test.counter.2:55|c",
        "storage.test.counter.10:55|c",
        "storage.test.counter.1:55|c",
        "storage.test.gauge.2:10|g",
        "storage.test.gauge.10:10|g",
        "storage.test.gauge.1:10|g",
        "storage.test.counter.9:55|c",
        "storage.test.counter.8:55|c",
        "storage.test.counter.7:55|c",
        "storage.test.counter.6:55|c",
        "storage.test.gauge.9:10|g",
        "storage.test.gauge.8:10|g",
        "storage.test.gauge.7:10|g",
        "storage.test.gauge.6:10|g",
        "storage.test.gauge.5:10|g",
        "storage.test.gauge.4:10|g",
        "storage.test.gauge.3:10|g"
      ]
      |> parse_packets()

    packets = get_statsd_packets(tid, %{mtu: 100})

    assert parse_packets(packets) == expected_metrics

    for packet <- packets do
      assert IO.iodata_length(packet) < 100
    end

    packets = get_statsd_packets(tid, %{mtu: 200})

    assert parse_packets(packets) == expected_metrics

    for packet <- packets do
      assert IO.iodata_length(packet) < 200
    end
  end

  defp get_statsd_packets(tid, opts \\ %{}) do
    formatter = opts[:formatter] || :standard
    mtu = opts[:mtu] || 1_000_000

    state = Statsd.make_state(%{formatter: formatter, mtu: mtu})

    {_cache, packets} =
      Storage.get_all_metrics(tid)
      |> Statsd.prepare(state)

    for p <- packets do
      IO.iodata_to_binary(p.lines)
    end
  end

  defp parse_packets(packets) do
    for packet <- packets, reduce: MapSet.new() do
      acc ->
        new =
          for metric <- parse_packet(IO.iodata_to_binary(packet)), into: MapSet.new() do
            metric
          end

        MapSet.union(acc, new)
    end
  end

  defp parse_packet(packet) do
    for line <- String.split(packet, "\n", trim: true) do
      {:ok, props, "", _, _, _} = StatsdParser.parse(line)
      metric_to_map(props)
    end
  end

  defp metric_to_map(kw) do
    Enum.into(kw, %{})
    |> Map.update(:tags, %{}, fn tags ->
      for {:tag, [name: name, value: value]} <- tags, into: %{} do
        {name, value}
      end
    end)
  end
end
