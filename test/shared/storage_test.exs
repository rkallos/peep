defmodule Peep.Storage.Test do
  @moduledoc """
  Sets up Storage backend test cases.

  ## Usage

  To test one or more Storage backends, set the `:test_storages` on the `:peep`
  configuration and require this file and the test helper, ie:

  # your_storage_test.exs
  Application.put_env(:peep, :test_storages, [{CustomStorage, 3}, {OtherStorage, []}])
  Code.require_file "../deps/peep/test/shared/test_helpers.ex", __DIR__
  Code.require_file "../deps/peep/test/shared/storage_test.exs", __DIR__

  """

  use ExUnit.Case, async: true

  alias Telemetry.Metrics

  @impls Application.compile_env(:peep, :test_storages)

  for impl <- @impls do
    test "#{inspect(impl)} - a counter counts its events per tags map" do
      event = event()
      counter = Metrics.counter("storage.test.counter", event_name: event, tags: [:even])

      check(unquote(impl),
        metrics: [counter],
        events: [{event, %{}, %{}}, {event, %{}, %{}}, {event, %{}, %{even: true}}],
        exp_scrape: %{counter => %{%{} => 2, %{even: true} => 1}}
      )
    end

    test "#{inspect(impl)} - a sum adds its measurements per tags map" do
      event = event()
      sum = Metrics.sum("storage.test.sum", event_name: event, measurement: :value, tags: [:even])

      check(unquote(impl),
        metrics: [sum],
        events: [
          {event, %{value: 2}, %{}},
          {event, %{value: 2}, %{}},
          {event, %{value: 3}, %{even: true}}
        ],
        exp_scrape: %{sum => %{%{} => 4, %{even: true} => 3}}
      )
    end

    test "#{inspect(impl)} - metrics of one event are stored under their own tags" do
      event = event()
      by_a = Metrics.counter("storage.test.by_a", event_name: event, tags: [:a])
      by_b = Metrics.counter("storage.test.by_b", event_name: event, tags: [:b])

      check(unquote(impl),
        metrics: [by_a, by_b],
        events: [{event, %{}, %{a: 1, b: 2}}],
        exp_scrape: %{by_a => %{%{a: 1} => 1}, by_b => %{%{b: 2} => 1}}
      )
    end

    test "#{inspect(impl)} - a last_value keeps its last measurement per tags map" do
      event = event()

      last_value =
        Metrics.last_value("storage.test.gauge",
          event_name: event,
          measurement: :value,
          tags: [:odd]
        )

      check(unquote(impl),
        metrics: [last_value],
        events: [
          {event, %{value: 1}, %{}},
          {event, %{value: 10}, %{}},
          {event, %{value: 9}, %{odd: true}}
        ],
        exp_scrape: %{last_value => %{%{} => 10, %{odd: true} => 9}}
      )
    end

    test "#{inspect(impl)} - binary tag values round-trip byte-for-byte" do
      event = event()
      counter = Metrics.counter("storage.test.counter", event_name: event, tags: [:t])

      last_value =
        Metrics.last_value("storage.test.gauge",
          event_name: event,
          measurement: :value,
          tags: [:t]
        )

      # Erlang binaries are byte strings, not necessarily UTF-8, so a storage
      # backend must not treat them as text - it has to hand back the exact
      # bytes it was given.
      utf8 = "héllo"
      not_utf8 = <<0xFF, 0xFE>>

      # Comparing whole maps compares the keys themselves, so a backend that
      # mangled the bytes can't pass by mangling both sides of a lookup.
      check(unquote(impl),
        metrics: [counter, last_value],
        events: [{event, %{value: 7}, %{t: utf8}}, {event, %{value: 7}, %{t: not_utf8}}],
        exp_scrape: %{
          counter => %{%{t: utf8} => 1, %{t: not_utf8} => 1},
          last_value => %{%{t: utf8} => 7, %{t: not_utf8} => 7}
        }
      )
    end

    test "#{inspect(impl)} - a distribution can be stored and retrieved" do
      event = event()

      dist =
        Metrics.distribution("storage.test.distribution",
          event_name: event,
          measurement: :value,
          reporter_options: [max_value: 1000]
        )

      check(unquote(impl),
        metrics: [dist],
        events: for(i <- 0..2000, do: {event, %{value: i}, %{}}),
        exp_scrape: %{
          dist => %{
            %{} => %{
              1.0 => 2,
              1.2222222222222223 => 0,
              1.4938271604938274 => 0,
              1.825788751714678 => 0,
              2.7274128266355073 => 0,
              2.231519585429051 => 1,
              3.3335045658878424 => 1,
              4.074283358307364 => 1,
              4.979679660153445 => 0,
              6.086275140187544 => 2,
              7.438780726895887 => 1,
              9.09184311065053 => 2,
              11.112252690795092 => 2,
              13.581642177638448 => 2,
              16.599784883780327 => 3,
              20.288625969064846 => 4,
              24.797209517745923 => 4,
              30.307700521689465 => 6,
              37.042745082064904 => 7,
              45.274466211412665 => 8,
              55.335458702837705 => 10,
              67.63222730346831 => 12,
              82.6616111486835 => 15,
              101.03085807061318 => 19,
              123.48215986408277 => 22,
              150.92263983387897 => 27,
              184.46100424140764 => 34,
              225.45233851727602 => 41,
              275.5528581877818 => 50,
              336.7868266739556 => 61,
              411.62834371261243 => 75,
              503.1013089820819 => 92,
              614.901599866989 => 111,
              751.5463998374311 => 137,
              918.5567109124158 => 167,
              1122.6804244485083 => 204,
              :infinity => 878,
              :sum => 2_001_000
            }
          }
        }
      )
    end

    test "#{inspect(impl)} - distribution bucket variability" do
      event = event()

      dist =
        Metrics.distribution("storage.test.distribution",
          event_name: event,
          measurement: :value,
          reporter_options: [max_value: 1000, bucket_variability: 0.25]
        )

      check(unquote(impl),
        metrics: [dist],
        events: for(i <- 0..1000, do: {event, %{value: i}, %{}}),
        exp_scrape: %{
          dist => %{
            %{} => %{
              1.0 => 2,
              1.6666666666666667 => 0,
              2.777777777777778 => 1,
              4.629629629629631 => 2,
              7.716049382716051 => 3,
              12.860082304526752 => 5,
              21.433470507544587 => 9,
              35.722450845907645 => 14,
              59.53741807651275 => 24,
              99.22903012752126 => 40,
              165.3817168792021 => 66,
              275.63619479867015 => 110,
              459.39365799778363 => 184,
              765.6560966629728 => 306,
              1276.093494438288 => 235,
              :infinity => 0,
              :sum => 500_500
            }
          }
        }
      )
    end

    test "#{inspect(impl)} - default distribution handles negative values" do
      event = event()

      dist =
        Metrics.distribution("storage.test.distribution",
          event_name: event,
          measurement: :value,
          reporter_options: [max_value: 500, bucket_variability: 0.25]
        )

      check(unquote(impl),
        metrics: [dist],
        events: for(i <- -500..500, do: {event, %{value: i}, %{}}),
        exp_scrape: %{
          dist => %{
            %{} => %{
              1.0 => 502,
              1.6666666666666667 => 0,
              2.777777777777778 => 1,
              4.629629629629631 => 2,
              7.716049382716051 => 3,
              12.860082304526752 => 5,
              21.433470507544587 => 9,
              35.722450845907645 => 14,
              59.53741807651275 => 24,
              99.22903012752126 => 40,
              165.3817168792021 => 66,
              275.63619479867015 => 110,
              459.39365799778363 => 184,
              765.6560966629728 => 41,
              :infinity => 0,
              :sum => 0
            }
          }
        }
      )
    end

    test "#{inspect(impl)} - events from concurrent processes are all recorded" do
      event = event()
      counter = Metrics.counter("storage.test.counter", event_name: event)
      sum = Metrics.sum("storage.test.sum", event_name: event, measurement: :value)

      dist =
        Metrics.distribution("storage.test.distribution",
          event_name: event,
          measurement: :value,
          reporter_options: [max_value: 1000]
        )

      check(unquote(impl),
        metrics: [counter, sum, dist],
        events: for(i <- 1..10, do: {event, %{value: i}, %{}}),
        tasks: 100,
        exp_scrape: %{
          counter => %{%{} => 1000},
          sum => %{%{} => 5500},
          dist => %{
            %{} => Peep.Test.distribution_series(dist, Enum.flat_map(1..100, fn _ -> 1..10 end))
          }
        }
      )
    end

    test "#{inspect(impl)} - metrics with a keep are only recorded for matching events" do
      event = event()
      keep = fn metadata -> metadata[:kept] == true end
      kept = Metrics.sum("storage.test.kept", event_name: event, measurement: :value, keep: keep)
      unfiltered = Metrics.sum("storage.test.unfiltered", event_name: event, measurement: :value)

      check(unquote(impl),
        metrics: [kept, unfiltered],
        events: [{event, %{value: 10}, %{kept: true}}, {event, %{value: 99}, %{kept: false}}],
        exp_scrape: %{kept => %{%{} => 10}, unfiltered => %{%{} => 109}}
      )
    end

    test "#{inspect(impl)} - storage_size/1" do
      metrics = prune_metrics()
      name = Peep.Test.start_peep!(storage: unquote(impl), metrics: metrics)

      for metric <- metrics, tags <- [%{}, %{foo: :bar}, %{baz: :quux}] do
        %{size: size_before, memory: mem_before} = Peep.storage_size(name)
        :telemetry.execute(metric.event_name, %{value: 5}, tags)
        %{size: size_after, memory: mem_after} = Peep.storage_size(name)

        assert size_after > size_before
        assert mem_after > mem_before
      end
    end

    test "#{inspect(impl)} - pruning every inserted tags map empties storage" do
      metrics = prune_metrics()

      check(unquote(impl),
        metrics: metrics,
        events: prune_events(metrics),
        prune: [%{foo: :bar}, %{baz: :quux}],
        exp_scrape: %{}
      )
    end

    test "#{inspect(impl)} - a pattern matching no tags map prunes nothing" do
      metrics = prune_metrics()

      check(unquote(impl),
        metrics: metrics,
        events: prune_events(metrics),
        prune: [%{foo: :bar, baz: :quux}],
        exp_scrape: pruned_scrape(metrics, [%{foo: :bar}, %{baz: :quux}])
      )
    end

    test "#{inspect(impl)} - patterns matching nothing don't stop the others" do
      metrics = prune_metrics()

      check(unquote(impl),
        metrics: metrics,
        events: prune_events(metrics),
        prune: [%{foo: :blah}, %{foo: :bar}],
        exp_scrape: pruned_scrape(metrics, [%{baz: :quux}])
      )
    end
  end

  defp check(impl, opts) do
    name = Peep.Test.start_peep!(storage: impl, metrics: Keyword.fetch!(opts, :metrics))
    events = Keyword.fetch!(opts, :events)

    emit = fn ->
      for {event, measurements, metadata} <- events do
        :telemetry.execute(event, measurements, metadata)
      end
    end

    case Keyword.get(opts, :tasks, 1) do
      1 -> emit.()
      tasks -> 1..tasks |> Enum.map(fn _ -> Task.async(emit) end) |> Task.await_many()
    end

    if patterns = opts[:prune] do
      assert Peep.prune_tags(name, patterns) == :ok
    end

    assert Peep.get_all_metrics(name) == Keyword.fetch!(opts, :exp_scrape)
  end

  defp prune_metrics do
    opts = [measurement: :value, tags: [:foo, :baz]]

    [
      Metrics.counter("storage.test.counter", [event_name: event()] ++ opts),
      Metrics.sum("storage.test.sum", [event_name: event()] ++ opts),
      Metrics.last_value("storage.test.gauge", [event_name: event()] ++ opts),
      Metrics.distribution(
        "storage.test.distribution",
        [event_name: event(), reporter_options: [max_value: 1000]] ++ opts
      )
    ]
  end

  defp prune_events(metrics) do
    for metric <- metrics, tags <- [%{foo: :bar}, %{baz: :quux}] do
      {metric.event_name, %{value: 5}, tags}
    end
  end

  # The scrape after `prune_events/1`, keeping only the series under `tags`.
  defp pruned_scrape(metrics, tags) do
    Map.new(metrics, fn metric ->
      value =
        case metric do
          %Metrics.Counter{} -> 1
          %Metrics.Distribution{} -> Peep.Test.distribution_series(metric, [5])
          _sum_or_last_value -> 5
        end

      {metric, Map.new(tags, &{&1, value})}
    end)
  end

  defp event, do: [Peep.Test.fresh_id()]
end
