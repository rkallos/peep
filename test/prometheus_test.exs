defmodule PrometheusTest do
  use ExUnit.Case

  alias Peep.{Prometheus, Storage}
  alias Telemetry.Metrics

  alias Peep.Support.StorageCounter

  test "counter formatting" do
    tid = Storage.new(StorageCounter.fresh_id())
    counter = Metrics.counter("prometheus.test.counter", description: "a counter")

    Storage.insert_metric(tid, counter, 1, foo: :bar, baz: "quux")

    expected = [
      "# HELP prometheus_test_counter a counter",
      "# TYPE prometheus_test_counter counter",
      ~s(prometheus_test_counter{baz="quux",foo="bar"} 1)
    ]

    assert export(tid) == lines_to_string(expected)
  end

  test "sum formatting" do
    tid = Storage.new(StorageCounter.fresh_id())
    sum = Metrics.sum("prometheus.test.sum", description: "a sum")

    Storage.insert_metric(tid, sum, 5, foo: :bar, baz: "quux")
    Storage.insert_metric(tid, sum, 3, foo: :bar, baz: "quux")

    expected = [
      "# HELP prometheus_test_sum a sum",
      "# TYPE prometheus_test_sum counter",
      ~s(prometheus_test_sum{baz="quux",foo="bar"} 8)
    ]

    assert export(tid) == lines_to_string(expected)
  end

  test "last_value formatting" do
    tid = Storage.new(StorageCounter.fresh_id())
    last_value = Metrics.last_value("prometheus.test.gauge", description: "a last_value")

    Storage.insert_metric(tid, last_value, 5, blee: :bloo, flee: "floo")

    expected = [
      "# HELP prometheus_test_gauge a last_value",
      "# TYPE prometheus_test_gauge gauge",
      ~s(prometheus_test_gauge{blee="bloo",flee="floo"} 5)
    ]

    assert export(tid) == lines_to_string(expected)
  end

  test "dist formatting" do
    tid = Storage.new(StorageCounter.fresh_id())

    dist =
      Metrics.distribution("prometheus.test.distribution",
        description: "a distribution",
        reporter_options: [max_value: 1000]
      )

    expected = []
    assert export(tid) == lines_to_string(expected)

    Storage.insert_metric(tid, dist, 1, glee: :gloo)

    expected = [
      "# HELP prometheus_test_distribution a distribution",
      "# TYPE prometheus_test_distribution histogram",
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.222222"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.493827"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.825789"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="2.23152"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="2.727413"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="3.333505"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="4.074283"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="4.97968"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="6.086275"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="7.438781"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="9.091843"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="11.112253"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="13.581642"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="16.599785"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="20.288626"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="24.79721"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="30.307701"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="37.042745"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="45.274466"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="55.335459"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="67.632227"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="82.661611"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="101.030858"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="123.48216"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="150.92264"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="184.461004"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="225.452339"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="275.552858"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="336.786827"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="411.628344"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="503.101309"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="614.9016"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="751.5464"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="918.556711"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1122.680424"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="+Inf"} 1),
      ~s(prometheus_test_distribution_sum{glee="gloo"} 1),
      ~s(prometheus_test_distribution_count{glee="gloo"} 1)
    ]

    assert export(tid) == lines_to_string(expected)

    for i <- 2..2000 do
      Storage.insert_metric(tid, dist, i, glee: :gloo)
    end

    expected = [
      "# HELP prometheus_test_distribution a distribution",
      "# TYPE prometheus_test_distribution histogram",
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.222222"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.493827"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.825789"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="2.23152"} 2),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="2.727413"} 2),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="3.333505"} 3),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="4.074283"} 4),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="4.97968"} 4),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="6.086275"} 6),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="7.438781"} 7),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="9.091843"} 9),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="11.112253"} 11),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="13.581642"} 13),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="16.599785"} 16),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="20.288626"} 20),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="24.79721"} 24),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="30.307701"} 30),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="37.042745"} 37),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="45.274466"} 45),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="55.335459"} 55),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="67.632227"} 67),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="82.661611"} 82),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="101.030858"} 101),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="123.48216"} 123),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="150.92264"} 150),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="184.461004"} 184),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="225.452339"} 225),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="275.552858"} 275),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="336.786827"} 336),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="411.628344"} 411),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="503.101309"} 503),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="614.9016"} 614),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="751.5464"} 751),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="918.556711"} 918),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1122.680424"} 1122),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="+Inf"} 2000),
      ~s(prometheus_test_distribution_sum{glee="gloo"} 2001000),
      ~s(prometheus_test_distribution_count{glee="gloo"} 2000)
    ]

    assert export(tid) == lines_to_string(expected)
  end

  test "dist formatting pow10" do
    tid = Storage.new(StorageCounter.fresh_id())

    dist =
      Metrics.distribution("prometheus.test.distribution",
        description: "a distribution",
        reporter_options: [
          max_value: 1000,
          peep_bucket_calculator: Peep.Buckets.PowersOfTen
        ]
      )

    expected = []
    assert export(tid) == lines_to_string(expected)

    Storage.insert_metric(tid, dist, 1, glee: :gloo)

    expected = [
      "# HELP prometheus_test_distribution a distribution",
      "# TYPE prometheus_test_distribution histogram",
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="10.0"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="100.0"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e3"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e4"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e5"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e6"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e7"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e8"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e9"} 1),
      ~s(prometheus_test_distribution_bucket{glee="gloo",le="+Inf"} 1),
      ~s(prometheus_test_distribution_sum{glee="gloo"} 1),
      ~s(prometheus_test_distribution_count{glee="gloo"} 1)
    ]

    assert export(tid) == lines_to_string(expected)

    for i <- 2..2000 do
      Storage.insert_metric(tid, dist, i, glee: :gloo)
    end

    expected =
      [
        "# HELP prometheus_test_distribution a distribution",
        "# TYPE prometheus_test_distribution histogram",
        ~s(prometheus_test_distribution_bucket{glee="gloo",le="10.0"} 9),
        ~s(prometheus_test_distribution_bucket{glee="gloo",le="100.0"} 99),
        ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e3"} 999),
        ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e4"} 2000),
        ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e5"} 2000),
        ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e6"} 2000),
        ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e7"} 2000),
        ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e8"} 2000),
        ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e9"} 2000),
        ~s(prometheus_test_distribution_bucket{glee="gloo",le="+Inf"} 2000),
        ~s(prometheus_test_distribution_sum{glee="gloo"} 2001000),
        ~s(prometheus_test_distribution_count{glee="gloo"} 2000)
      ]

    assert export(tid) == lines_to_string(expected)
  end

  test "non-number values" do
    tid = Storage.new(StorageCounter.fresh_id())

    last_value =
      Metrics.last_value(
        "prometheus.test.gauge",
        description: "a last_value",
        tags: [:from]
      )

    Storage.insert_metric(tid, last_value, true, from: true)
    Storage.insert_metric(tid, last_value, false, from: false)
    Storage.insert_metric(tid, last_value, nil, from: nil)

    expected = [
      "# HELP prometheus_test_gauge a last_value",
      "# TYPE prometheus_test_gauge gauge",
      ~s(prometheus_test_gauge{from="false"} 0),
      ~s(prometheus_test_gauge{from="nil"} 0),
      ~s(prometheus_test_gauge{from="true"} 1)
    ]

    assert export(tid) == lines_to_string(expected)
  end

  defp export(tid) do
    Storage.get_all_metrics(tid)
    |> Prometheus.export()
    |> IO.iodata_to_binary()
  end

  defp lines_to_string(lines) do
    lines
    |> Enum.intersperse(?\n)
    |> then(&[&1, ?\n])
    |> IO.iodata_to_binary()
  end
end
