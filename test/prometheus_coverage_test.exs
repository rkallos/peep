defmodule PrometheusCoverageTest do
  use ExUnit.Case, async: true

  alias Peep.Prometheus
  alias Peep.Support.StorageCounter
  alias Telemetry.Metrics

  defp export(name) do
    Peep.get_all_metrics(name)
    |> Prometheus.export()
    |> IO.iodata_to_binary()
  end

  test "format_value handles boolean and nil values" do
    counter = Metrics.counter("bool.test.counter", description: "test")

    # Construct data directly - format_value(true), format_value(false), format_value(nil)
    data = [
      {counter,
       [
         {%{flag: "on"}, true},
         {%{flag: "off"}, false},
         {%{flag: "none"}, nil}
       ]}
    ]

    result = data |> Prometheus.export() |> IO.iodata_to_binary()

    assert result =~ ~s(bool_test_counter{flag="on"} 1)
    assert result =~ ~s(bool_test_counter{flag="off"} 0)
    assert result =~ ~s(bool_test_counter{flag="none"} 0)
  end

  test "escape handles nil tag values" do
    counter = Metrics.counter("nil.tag.counter", description: "test")

    data = [{counter, [{%{key: nil}, 1}]}]

    result = data |> Prometheus.export() |> IO.iodata_to_binary()
    assert result =~ ~s(key="nil")
  end

  test "escape handles backslash in tag values" do
    counter = Metrics.counter("bs.tag.counter", description: "test")

    data = [{counter, [{%{path: "C:\\Users\\test"}, 1}]}]

    result = data |> Prometheus.export() |> IO.iodata_to_binary()
    assert result =~ ~s(path="C:\\\\Users\\\\test")
  end

  test "escape_help handles backslash and newline in descriptions" do
    counter = Metrics.counter("help.escape.counter", description: "a \\ backslash\nand newline")

    data = [{counter, [{%{}, 5}]}]

    result = data |> Prometheus.export() |> IO.iodata_to_binary()
    assert result =~ "# HELP help_escape_counter a \\\\ backslash\\nand newline"
  end

  test "format_name strips leading non-letter characters" do
    name = StorageCounter.fresh_id()

    # Metric name starting with a digit
    counter =
      Metrics.counter("1.leading.digit",
        event_name: [name, :leading],
        description: "test"
      )

    opts = [name: name, metrics: [counter]]
    {:ok, _pid} = Peep.start_link(opts)

    Peep.insert_metric(name, counter, 1, %{})

    result = export(name)
    # The leading "1" should be stripped, leaving "leading_digit"
    assert result =~ "leading_digit"
    refute result =~ "1_leading"
  end

  test "format_name strips invalid characters from name body" do
    counter = Metrics.counter("has-dash.and.dots", description: "test")

    data = [{counter, [{%{}, 3}]}]

    result = data |> Prometheus.export() |> IO.iodata_to_binary()
    # Dashes are stripped, dots become underscores (via Enum.join("_"))
    # "has-dash_and_dots" -> "has" then "dash_and_dots" with dash stripped -> "hasdash_and_dots"
    assert result =~ "hasdash_and_dots"
  end

  test "distribution without labels" do
    name = StorageCounter.fresh_id()

    dist =
      Metrics.distribution("no.label.dist",
        event_name: [name, :nolabel],
        description: "a distribution",
        reporter_options: [max_value: 100]
      )

    opts = [name: name, metrics: [dist]]
    {:ok, _pid} = Peep.start_link(opts)

    Peep.insert_metric(name, dist, 50, %{})

    result = export(name)

    # Without labels, buckets use space separator not curly braces for sum/count
    assert result =~ "no_label_dist_bucket{le=\""
    assert result =~ ~r/no_label_dist_sum \d+/
    assert result =~ ~r/no_label_dist_count \d+/
  end

  test "counter without labels" do
    name = StorageCounter.fresh_id()

    counter =
      Metrics.counter("no.label.counter",
        event_name: [name, :nolabel_counter],
        description: "test"
      )

    opts = [name: name, metrics: [counter]]
    {:ok, _pid} = Peep.start_link(opts)

    Peep.insert_metric(name, counter, 1, %{})

    result = export(name)
    assert result =~ ~r/no_label_counter \d+/
  end
end
