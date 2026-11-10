defmodule PrometheusTest do
  use ExUnit.Case, async: true

  alias Peep.Prometheus
  alias Telemetry.Metrics

  # Test struct that doesn't implement String.Chars
  defmodule TestError do
    defstruct [:reason, :code]
  end

  defmodule NanosecondBuckets do
    use Peep.Buckets.Custom, buckets: [5_000, 50_000, 500_000]
  end

  @kilo [peep_export_conversion_factor: 0.001]

  test "an empty scrape exports nothing but EOF" do
    check(scrape: %{}, exp_export: [])
  end

  test "counter formatting" do
    counter = Metrics.counter("prometheus.test.counter", description: "a counter")

    check(
      scrape: %{counter => %{%{foo: :bar, baz: "quux"} => 1}},
      exp_export: [
        "# HELP prometheus_test_counter a counter",
        "# TYPE prometheus_test_counter counter",
        ~s(prometheus_test_counter{baz="quux",foo="bar"} 1)
      ]
    )
  end

  describe "sum" do
    test "formatting" do
      sum = Metrics.sum("prometheus.test.sum", description: "a sum")

      check(
        scrape: %{sum => %{%{foo: :bar, baz: "quux"} => 8}},
        exp_export: [
          "# HELP prometheus_test_sum a sum",
          "# TYPE prometheus_test_sum counter",
          ~s(prometheus_test_sum{baz="quux",foo="bar"} 8)
        ]
      )
    end

    test "custom type" do
      sum =
        Metrics.sum("prometheus.test.sum",
          description: "a sum",
          reporter_options: [prometheus_type: "gauge"]
        )

      check(
        scrape: %{sum => %{%{foo: :bar, baz: "quux"} => 8}},
        exp_export: [
          "# HELP prometheus_test_sum a sum",
          "# TYPE prometheus_test_sum gauge",
          ~s(prometheus_test_sum{baz="quux",foo="bar"} 8)
        ]
      )
    end
  end

  describe "last_value" do
    test "formatting" do
      last_value = Metrics.last_value("prometheus.test.gauge", description: "a last_value")

      check(
        scrape: %{last_value => %{%{blee: :bloo, flee: "floo"} => 5}},
        exp_export: [
          "# HELP prometheus_test_gauge a last_value",
          "# TYPE prometheus_test_gauge gauge",
          ~s(prometheus_test_gauge{blee="bloo",flee="floo"} 5)
        ]
      )
    end

    test "custom type" do
      last_value =
        Metrics.last_value("prometheus.test.gauge",
          description: "a last_value",
          reporter_options: [prometheus_type: :sum]
        )

      check(
        scrape: %{last_value => %{%{blee: :bloo, flee: "floo"} => 5}},
        exp_export: [
          "# HELP prometheus_test_gauge a last_value",
          "# TYPE prometheus_test_gauge sum",
          ~s(prometheus_test_gauge{blee="bloo",flee="floo"} 5)
        ]
      )
    end
  end

  describe "distribution" do
    test "a single sample" do
      dist =
        Metrics.distribution("prometheus.test.distribution",
          description: "a distribution",
          reporter_options: [max_value: 1000]
        )

      check(
        scrape: %{dist => %{%{glee: :gloo} => Peep.Test.distribution_series(dist, [1])}},
        exp_export: [
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
      )
    end

    test "bucket counts are cumulative" do
      dist =
        Metrics.distribution("prometheus.test.distribution",
          description: "a distribution",
          reporter_options: [max_value: 1000]
        )

      check(
        scrape: %{
          dist => %{%{glee: :gloo} => Peep.Test.distribution_series(dist, 1..2000)}
        },
        exp_export: [
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
      )
    end

    test "powers of ten" do
      dist =
        Metrics.distribution("prometheus.test.distribution",
          description: "a distribution",
          reporter_options: [
            max_value: 1000,
            peep_bucket_calculator: Peep.Buckets.PowersOfTen
          ]
        )

      check(
        scrape: %{
          dist => %{%{glee: :gloo} => Peep.Test.distribution_series(dist, [1, 50, 500, 5000])}
        },
        exp_export: [
          "# HELP prometheus_test_distribution a distribution",
          "# TYPE prometheus_test_distribution histogram",
          ~s(prometheus_test_distribution_bucket{glee="gloo",le="10.0"} 1),
          ~s(prometheus_test_distribution_bucket{glee="gloo",le="100.0"} 2),
          ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e3"} 3),
          ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e4"} 4),
          ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e5"} 4),
          ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e6"} 4),
          ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e7"} 4),
          ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e8"} 4),
          ~s(prometheus_test_distribution_bucket{glee="gloo",le="1.0e9"} 4),
          ~s(prometheus_test_distribution_bucket{glee="gloo",le="+Inf"} 4),
          ~s(prometheus_test_distribution_sum{glee="gloo"} 5551),
          ~s(prometheus_test_distribution_count{glee="gloo"} 4)
        ]
      )
    end
  end

  test "metric names keep only the characters Prometheus allows" do
    counter = Metrics.counter("1st.my-counter", description: "a counter")

    check(
      scrape: %{counter => %{%{} => 1}},
      exp_export: [
        "# HELP st_mycounter a counter",
        "# TYPE st_mycounter counter",
        "st_mycounter 1"
      ]
    )
  end

  test "a nil label value is exported as nil" do
    counter = Metrics.counter("prometheus.test.counter", description: "a counter")

    check(
      scrape: %{counter => %{%{foo: nil} => 1}},
      exp_export: [
        "# HELP prometheus_test_counter a counter",
        "# TYPE prometheus_test_counter counter",
        ~s(prometheus_test_counter{foo="nil"} 1)
      ]
    )
  end

  test "backslashes and newlines are escaped in labels and help" do
    counter = Metrics.counter("prometheus.test.counter", description: "a \\ b\nc")

    check(
      scrape: %{counter => %{%{path: "a\\b"} => 1}},
      exp_export: [
        "# HELP prometheus_test_counter a \\\\ b\\nc",
        "# TYPE prometheus_test_counter counter",
        ~S(prometheus_test_counter{path="a\\b"} 1)
      ]
    )
  end

  describe "peep_export_conversion_factor" do
    test "converts a sum" do
      sum = Metrics.sum("prometheus.test.sum", reporter_options: @kilo)

      check(
        scrape: %{sum => %{%{} => 3000}},
        exp_export: [
          "# HELP prometheus_test_sum ",
          "# TYPE prometheus_test_sum counter",
          "prometheus_test_sum 3.0"
        ]
      )
    end

    test "converts a last_value" do
      last_value = Metrics.last_value("prometheus.test.gauge", reporter_options: @kilo)

      check(
        scrape: %{last_value => %{%{foo: :bar} => 1500}},
        exp_export: [
          "# HELP prometheus_test_gauge ",
          "# TYPE prometheus_test_gauge gauge",
          ~s(prometheus_test_gauge{foo="bar"} 1.5)
        ]
      )
    end

    test "converts a distribution's sum and bucket bounds" do
      dist = Metrics.distribution("prometheus.test.dist", reporter_options: @kilo)

      check(
        scrape: %{dist => %{%{} => %{"1000.0" => 1, "2000.0" => 2, infinity: 1, sum: 7500}}},
        exp_export: [
          "# HELP prometheus_test_dist ",
          "# TYPE prometheus_test_dist histogram",
          ~s(prometheus_test_dist_bucket{le="1.0"} 1),
          ~s(prometheus_test_dist_bucket{le="2.0"} 3),
          ~s(prometheus_test_dist_bucket{le="+Inf"} 4),
          "prometheus_test_dist_sum 7.5",
          "prometheus_test_dist_count 4"
        ]
      )
    end

    test "does not convert a counter" do
      counter = Metrics.counter("prometheus.test.counter", reporter_options: @kilo)

      check(
        scrape: %{counter => %{%{} => 3000}},
        exp_export: [
          "# HELP prometheus_test_counter ",
          "# TYPE prometheus_test_counter counter",
          "prometheus_test_counter 3000"
        ]
      )
    end

    test "regression: a distribution of nanoseconds has a sum in seconds" do
      event = [Peep.Test.fresh_id()]

      dist =
        Metrics.distribution("prometheus.test.duration",
          event_name: event,
          measurement: :duration,
          unit: :nanosecond,
          reporter_options: [
            peep_bucket_calculator: NanosecondBuckets,
            peep_export_conversion_factor: 1.0e-9
          ]
        )

      name = Peep.Test.start_peep!(metrics: [dist])
      for duration <- [2_000, 4_000, 42_312], do: :telemetry.execute(event, %{duration: duration})

      check(
        scrape: Peep.get_all_metrics(name),
        exp_export: [
          "# HELP prometheus_test_duration ",
          "# TYPE prometheus_test_duration histogram",
          ~s(prometheus_test_duration_bucket{le="5.0e-6"} 2),
          ~s(prometheus_test_duration_bucket{le="5.0e-5"} 3),
          ~s(prometheus_test_duration_bucket{le="0.0005"} 3),
          ~s(prometheus_test_duration_bucket{le="+Inf"} 3),
          "prometheus_test_duration_sum 4.8312e-5",
          "prometheus_test_duration_count 3"
        ]
      )
    end
  end

  test "regression: label escaping" do
    counter = Metrics.counter("prometheus.test.counter", description: "a counter")

    check(
      scrape: %{
        counter => %{
          %{atom: "\"string\""} => 1,
          %{"\"string\"" => :atom} => 1,
          %{"\"string\"" => "\"string\""} => 1,
          %{"string" => "string\n"} => 1
        }
      },
      exp_export: [
        "# HELP prometheus_test_counter a counter",
        "# TYPE prometheus_test_counter counter",
        ~s(prometheus_test_counter{atom="\\\"string\\\""} 1),
        ~s(prometheus_test_counter{\"string\"="atom"} 1),
        ~s(prometheus_test_counter{\"string\"="\\\"string\\\""} 1),
        ~s(prometheus_test_counter{string="string\\n"} 1)
      ]
    )
  end

  test "regression: handle structs without String.Chars" do
    counter = Metrics.counter("prometheus.test.counter", description: "a counter")

    check(
      scrape: %{counter => %{%{error: %TestError{reason: :tcp_closed, code: 1001}} => 1}},
      exp_export: [
        "# HELP prometheus_test_counter a counter",
        "# TYPE prometheus_test_counter counter",
        ~s(prometheus_test_counter{error="%PrometheusTest.TestError{reason: :tcp_closed, code: 1001}"} 1)
      ]
    )
  end

  defp check(scrape: scrape, exp_export: exp_export) do
    assert IO.iodata_to_binary(Prometheus.export(scrape)) ==
             Enum.map_join(exp_export, &(&1 <> "\n")) <> "# EOF\n"
  end
end
