defmodule StatsdTest do
  use ExUnit.Case

  alias Peep.Statsd
  alias Telemetry.Metrics

  alias Peep.Support.StorageCounter

  @impls [:default, :striped, :default_prehashed]

  for impl <- @impls do
    test "#{impl} - a counter can be formatted" do
      name = StorageCounter.fresh_id()

      counter = Metrics.counter("statsd.test.counter")

      opts = [
        name: name,
        metrics: [counter],
        storage: unquote(impl)
      ]

      {:ok, _pid} = Peep.start_link(opts)

      for i <- 1..10 do
        Peep.insert_metric(name, counter, 1, %{})

        if rem(i, 2) == 0 do
          Peep.insert_metric(name, counter, 1, %{even: true})
        end
      end

      expected = ["statsd.test.counter:10|c", "statsd.test.counter:5|c|#even:true"]
      assert parse_packets(get_statsd_packets(name)) == parse_packets(expected)
    end

    test "#{impl} - a sum can be formatted" do
      name = StorageCounter.fresh_id()

      sum = Metrics.sum("statsd.test.sum")

      opts = [
        name: name,
        metrics: [sum],
        storage: unquote(impl)
      ]

      {:ok, _pid} = Peep.start_link(opts)

      for i <- 1..10 do
        Peep.insert_metric(name, sum, 1, %{})

        if rem(i, 2) == 0 do
          Peep.insert_metric(name, sum, 1, %{even: true})
        end
      end

      expected = ["statsd.test.sum:10|c", "statsd.test.sum:5|c|#even:true"]
      assert parse_packets(get_statsd_packets(name)) == parse_packets(expected)
    end

    test "#{impl} - a last_value can be formatted" do
      name = StorageCounter.fresh_id()

      last_value = Metrics.last_value("statsd.test.gauge")

      opts = [
        name: name,
        metrics: [last_value],
        storage: unquote(impl)
      ]

      {:ok, _pid} = Peep.start_link(opts)

      for i <- 1..10 do
        Peep.insert_metric(name, last_value, i, %{})

        if rem(i, 2) == 1 do
          Peep.insert_metric(name, last_value, i, %{odd: true})
        end
      end

      expected = ["statsd.test.gauge:10|g", "statsd.test.gauge:9|g|#odd:true"]
      assert parse_packets(get_statsd_packets(name)) == parse_packets(expected)
    end

    test "#{impl} - a distribution can be formatted (standard)" do
      name = StorageCounter.fresh_id()

      dist = Metrics.distribution("statsd.test.dist", reporter_options: [max_value: 1000])

      opts = [
        name: name,
        metrics: [dist],
        storage: unquote(impl)
      ]

      {:ok, _pid} = Peep.start_link(opts)

      for i <- 1..1000 do
        Peep.insert_metric(name, dist, i, %{})

        if rem(i, 100) == 0 do
          Peep.insert_metric(name, dist, i, %{foo: :bar})
        end
      end

      expected = [
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
        #
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

      packets = get_statsd_packets(name, %{formatter: :standard})

      assert parse_packets(packets) == parse_packets(expected)
    end

    test "#{impl} - a distribution can be formatted (datadog)" do
      name = StorageCounter.fresh_id()

      dist = Metrics.distribution("statsd.test.dist", reporter_options: [max_value: 1000])

      opts = [
        name: name,
        metrics: [dist],
        storage: unquote(impl)
      ]

      {:ok, _pid} = Peep.start_link(opts)

      for i <- 1..1000 do
        Peep.insert_metric(name, dist, i, %{})

        if rem(i, 100) == 0 do
          Peep.insert_metric(name, dist, i, %{foo: :bar})
        end
      end

      expected = [
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
        #
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

      packets = get_statsd_packets(name, %{formatter: :datadog})
      assert parse_packets(packets) == parse_packets(expected)
    end

    test "#{impl} - metrics are batched according to mtu option" do
      name = StorageCounter.fresh_id()

      sum = fn i -> Metrics.sum("statsd.test.sum.#{i}") end
      last_value = fn i -> Metrics.last_value("statsd.test.gauge.#{i}") end

      metrics =
        Enum.reduce(1..10, [], fn i, acc ->
          [sum.(i), last_value.(i) | acc]
        end)

      opts = [
        name: name,
        metrics: metrics,
        storage: unquote(impl)
      ]

      {:ok, _pid} = Peep.start_link(opts)

      for i <- 1..10 do
        sum = sum.(i)
        last_value = last_value.(i)

        for j <- 1..10 do
          Peep.insert_metric(name, sum, j, %{})
          Peep.insert_metric(name, last_value, j, %{})
        end
      end

      expected_metrics =
        [
          "statsd.test.sum.5:55|c",
          "statsd.test.sum.4:55|c",
          "statsd.test.sum.3:55|c",
          "statsd.test.sum.2:55|c",
          "statsd.test.sum.10:55|c",
          "statsd.test.sum.1:55|c",
          "statsd.test.gauge.2:10|g",
          "statsd.test.gauge.10:10|g",
          "statsd.test.gauge.1:10|g",
          "statsd.test.sum.9:55|c",
          "statsd.test.sum.8:55|c",
          "statsd.test.sum.7:55|c",
          "statsd.test.sum.6:55|c",
          "statsd.test.gauge.9:10|g",
          "statsd.test.gauge.8:10|g",
          "statsd.test.gauge.7:10|g",
          "statsd.test.gauge.6:10|g",
          "statsd.test.gauge.5:10|g",
          "statsd.test.gauge.4:10|g",
          "statsd.test.gauge.3:10|g"
        ]
        |> parse_packets()

      packets = get_statsd_packets(name, %{mtu: 100})

      assert parse_packets(packets) == expected_metrics

      for packet <- packets do
        assert IO.iodata_length(packet) <= 100
      end

      packets = get_statsd_packets(name, %{mtu: 200})

      assert parse_packets(packets) == expected_metrics

      for packet <- packets do
        assert IO.iodata_length(packet) <= 200
      end
    end
  end

  defp get_statsd_packets(name, opts \\ %{}) do
    formatter = opts[:formatter] || :standard
    mtu = opts[:mtu] || 1_000_000

    state = Statsd.make_state(%{formatter: formatter, mtu: mtu})

    {_cache, packets} =
      Peep.get_all_metrics(name)
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
