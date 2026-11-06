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
              "1.0" => 2,
              "1.222222" => 0,
              "1.493827" => 0,
              "1.825789" => 0,
              "2.727413" => 0,
              "2.23152" => 1,
              "3.333505" => 1,
              "4.074283" => 1,
              "4.97968" => 0,
              "6.086275" => 2,
              "7.438781" => 1,
              "9.091843" => 2,
              "11.112253" => 2,
              "13.581642" => 2,
              "16.599785" => 3,
              "20.288626" => 4,
              "24.79721" => 4,
              "30.307701" => 6,
              "37.042745" => 7,
              "45.274466" => 8,
              "55.335459" => 10,
              "67.632227" => 12,
              "82.661611" => 15,
              "101.030858" => 19,
              "123.48216" => 22,
              "150.92264" => 27,
              "184.461004" => 34,
              "225.452339" => 41,
              "275.552858" => 50,
              "336.786827" => 61,
              "411.628344" => 75,
              "503.101309" => 92,
              "614.9016" => 111,
              "751.5464" => 137,
              "918.556711" => 167,
              "1122.680424" => 204,
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
              "1.0" => 2,
              "1.666667" => 0,
              "2.777778" => 1,
              "4.62963" => 2,
              "7.716049" => 3,
              "12.860082" => 5,
              "21.433471" => 9,
              "35.722451" => 14,
              "59.537418" => 24,
              "99.22903" => 40,
              "165.381717" => 66,
              "275.636195" => 110,
              "459.393658" => 184,
              "765.656097" => 306,
              "1276.093494" => 235,
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
              "1.0" => 502,
              "1.666667" => 0,
              "2.777778" => 1,
              "4.62963" => 2,
              "7.716049" => 3,
              "12.860082" => 5,
              "21.433471" => 9,
              "35.722451" => 14,
              "59.537418" => 24,
              "99.22903" => 40,
              "165.381717" => 66,
              "275.636195" => 110,
              "459.393658" => 184,
              "765.656097" => 41,
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
