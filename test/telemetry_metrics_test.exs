defmodule TelemetryMetricsTest do
  @moduledoc """
  Every option `Telemetry.Metrics` accepts, in each of its forms, for every
  metric type Peep supports.
  """

  use ExUnit.Case, async: true

  alias Telemetry.Metrics

  one_event = quote(do: [{%{value: 2}, %{}}])
  one_value = quote(do: [exp_values: %{%{} => [2]}])

  keep_events =
    quote(do: [{%{value: 2}, %{a: 1}}, {%{value: 3}, %{a: 2}}, {%{value: 4}, %{a: 2}}])

  # {title, metric options, [{measurements, metadata}], expectations}. The rows
  # are quoted because they hold functions; each test evaluates its own.
  variants =
    quote do
      [
        {"name as a string", [name: "compat.#{Peep.Test.fresh_id()}.value"], unquote(one_event),
         unquote(one_value)},
        {"name as a list of atoms", [name: [:compat, Peep.Test.fresh_id(), :value]],
         unquote(one_event), unquote(one_value)},
        {"event_name as a list of atoms",
         [name: "compat.test.value", event_name: [:compat, Peep.Test.fresh_id()]],
         unquote(one_event), unquote(one_value)},
        {"event_name as a string",
         [name: "compat.test.value", event_name: "compat.#{Peep.Test.fresh_id()}"],
         unquote(one_event), unquote(one_value)},
        {"measurement as a key", [measurement: :other], [{%{value: 2, other: 5}, %{}}],
         [exp_values: %{%{} => [5]}]},
        {"measurement as a function of the measurements", [measurement: &(&1.a + &1.b)],
         [{%{a: 2, b: 3}, %{}}], [exp_values: %{%{} => [5]}]},
        {"measurement as a function of the measurements and metadata",
         [measurement: &(&1.value * &2.factor)], [{%{value: 2}, %{factor: 3}}],
         [exp_values: %{%{} => [6]}]},
        {"tags as a list of keys", [tags: [:a, :b]],
         [{%{value: 2}, %{a: 1, b: 2, c: 3}}, {%{value: 3}, %{a: 1}}],
         [exp_values: %{%{a: 1, b: 2} => [2], %{a: 1} => [3]}]},
        {"tags as a function of the metadata", [tags: &%{sum: &1.a + &1.b}],
         [{%{value: 2}, %{a: 1, b: 2}}, {%{value: 3}, %{a: 2, b: 1}}],
         [exp_values: %{%{sum: 3} => [2, 3]}]},
        {"tag_values transforms the metadata that tags are taken from",
         [tags: [:sum], tag_values: &%{sum: &1.a + &1.b, a: &1.a}],
         [{%{value: 2}, %{a: 1, b: 2}}], [exp_values: %{%{sum: 3} => [2]}]},
        {"tag_values is not applied when tags is a function",
         [tags: &Map.take(&1, [:a]), tag_values: &%{a: &1.a * 10}], [{%{value: 2}, %{a: 1}}],
         [exp_values: %{%{a: 1} => [2]}]},
        {"keep as a function of the metadata", [keep: &(&1.a == 2)], unquote(keep_events),
         [exp_values: %{%{} => [3, 4]}]},
        {"keep as a function of the metadata and measurements",
         [keep: &(&1.a == 2 and &2.value > 3)], unquote(keep_events),
         [exp_values: %{%{} => [4]}]},
        {"drop as a function of the metadata", [drop: &(&1.a == 2)], unquote(keep_events),
         [exp_values: %{%{} => [2]}]},
        {"drop as a function of the metadata and measurements",
         [drop: &(&1.a == 2 and &2.value > 3)], unquote(keep_events),
         [exp_values: %{%{} => [2, 3]}]},
        {"unit as an atom", [unit: :byte], unquote(one_event), unquote(one_value)},
        {"unit as a conversion that multiplies by a whole number",
         [unit: {:second, :millisecond}], unquote(one_event), [exp_values: %{%{} => [2000]}]},
        {"unit as a conversion between byte units", [unit: {:byte, :kilobyte}],
         [{%{value: 3000}, %{}}, {%{value: 6000}, %{}}],
         [exp_values: %{%{} => [3.0, 6.0]}, floats?: true]},
        {"unit as a conversion between time units", [unit: {:native, :millisecond}],
         [{%{value: System.convert_time_unit(5, :millisecond, :native)}, %{}}],
         [exp_values: %{%{} => [5.0]}, floats?: true]},
        {"description",
         [
           name: "compat.described.value",
           event_name: [:compat, Peep.Test.fresh_id()],
           description: "what it measures"
         ], unquote(one_event),
         [
           exp_values: %{%{} => [2]},
           exp_help: "# HELP compat_described_value what it measures"
         ]},
        {"reporter_options Peep doesn't know", [reporter_options: [unknown: :option]],
         unquote(one_event), unquote(one_value)}
      ]
    end

  for type <- [:counter, :sum, :last_value, :distribution],
      {:{}, _, [title, metric_opts, events, exp]} <- variants do
    if type == :sum and exp[:floats?], do: @tag(capture_log: true)

    test "#{type}: #{title}" do
      check(unquote(type), unquote(metric_opts), unquote(events), unquote(exp))
    end
  end

  # `exp_values` maps each tags map to the values recorded under it, in order.
  # With `floats?`, those are floats, which the default storage can't add to a
  # sum: its handler is detached.
  defp check(type, metric_opts, events, exp) do
    {name, metric_opts} =
      Keyword.pop_lazy(metric_opts, :name, fn -> "compat.#{Peep.Test.fresh_id()}.value" end)

    metric = apply(Metrics, type, [name, metric_opts])
    peep = Peep.Test.start_peep!(metrics: [metric])

    for {measurements, metadata} <- events do
      :telemetry.execute(metric.event_name, measurements, metadata)
    end

    scrape = Peep.get_all_metrics(peep)
    exp_values = Keyword.fetch!(exp, :exp_values)

    if type == :sum and exp[:floats?] do
      assert :telemetry.list_handlers(metric.event_name) == []
      assert scrape == %{}
    else
      exp_series = Map.new(exp_values, fn {tags, values} -> {tags, series(metric, values)} end)
      assert scrape == %{metric => exp_series}
    end

    if exp_help = exp[:exp_help] do
      export = scrape |> Peep.Prometheus.export() |> IO.iodata_to_binary()
      assert exp_help in String.split(export, "\n")
    end
  end

  defp series(%Metrics.Counter{}, values), do: length(values)
  defp series(%Metrics.Sum{}, values), do: Enum.sum(values)
  defp series(%Metrics.LastValue{}, values), do: List.last(values)

  defp series(%Metrics.Distribution{} = dist, values),
    do: Peep.Test.distribution_series(dist, values)
end
