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
    test "#{inspect(impl)} - a counter counts its inserts per tags map" do
      counter = Metrics.counter("storage.test.counter")

      check(unquote(impl),
        metrics: [counter],
        inserts: [{counter, 1, %{}}, {counter, 1, %{}}, {counter, 1, %{even: true}}],
        exp_scrape: %{counter => %{%{} => 2, %{even: true} => 1}}
      )
    end

    test "#{inspect(impl)} - a sum adds its inserts per tags map" do
      sum = Metrics.sum("storage.test.sum")

      check(unquote(impl),
        metrics: [sum],
        inserts: [{sum, 2, %{}}, {sum, 2, %{}}, {sum, 3, %{even: true}}],
        exp_scrape: %{sum => %{%{} => 4, %{even: true} => 3}}
      )
    end

    test "#{inspect(impl)} - a last_value keeps its last insert per tags map" do
      last_value = Metrics.last_value("storage.test.gauge")

      check(unquote(impl),
        metrics: [last_value],
        inserts: [{last_value, 1, %{}}, {last_value, 10, %{}}, {last_value, 9, %{odd: true}}],
        exp_scrape: %{last_value => %{%{} => 10, %{odd: true} => 9}}
      )
    end

    test "#{inspect(impl)} - binary tag values round-trip byte-for-byte" do
      counter = Metrics.counter("storage.test.counter", tags: [:t])
      last_value = Metrics.last_value("storage.test.gauge", tags: [:t])

      # Erlang binaries are byte strings, not necessarily UTF-8, so a storage
      # backend must not treat them as text - it has to hand back the exact
      # bytes it was given.
      utf8 = "héllo"
      not_utf8 = <<0xFF, 0xFE>>

      # Comparing whole maps compares the keys themselves, so a backend that
      # mangled the bytes can't pass by mangling both sides of a lookup.
      check(unquote(impl),
        metrics: [counter, last_value],
        inserts:
          Enum.flat_map([utf8, not_utf8], &[{counter, 1, %{t: &1}}, {last_value, 7, %{t: &1}}]),
        exp_scrape: %{
          counter => %{%{t: utf8} => 1, %{t: not_utf8} => 1},
          last_value => %{%{t: utf8} => 7, %{t: not_utf8} => 7}
        }
      )
    end

    test "#{inspect(impl)} - a distribution can be stored and retrieved" do
      dist =
        Metrics.distribution("storage.test.distribution", reporter_options: [max_value: 1000])

      check(unquote(impl),
        metrics: [dist],
        inserts: for(i <- 0..2000, do: {dist, i, %{}}),
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
      dist =
        Metrics.distribution("storage.test.distribution",
          reporter_options: [max_value: 1000, bucket_variability: 0.25]
        )

      check(unquote(impl),
        metrics: [dist],
        inserts: for(i <- 0..1000, do: {dist, i, %{}}),
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
      dist =
        Metrics.distribution("storage.test.distribution",
          reporter_options: [max_value: 500, bucket_variability: 0.25]
        )

      check(unquote(impl),
        metrics: [dist],
        inserts: for(i <- -500..500, do: {dist, i, %{}}),
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

    test "#{inspect(impl)} - concurrent inserts are all recorded" do
      counter = Metrics.counter("storage.test.counter")
      sum = Metrics.sum("storage.test.sum")

      dist =
        Metrics.distribution("storage.test.distribution", reporter_options: [max_value: 1000])

      check(unquote(impl),
        metrics: [counter, sum, dist],
        inserts: Enum.flat_map(1..10, &[{counter, 1, %{}}, {sum, &1, %{}}, {dist, &1, %{}}]),
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

    test "#{inspect(impl)} - storage_size/1" do
      counter = Metrics.counter("storage.test.counter")
      sum = Metrics.sum("storage.test.sum")
      last_value = Metrics.last_value("storage.test.gauge")

      dist =
        Metrics.distribution("storage.test.distribution", reporter_options: [max_value: 1000])

      metrics = [counter, sum, last_value, dist]

      name = Peep.Test.start_peep!(storage: unquote(impl), metrics: metrics)

      tags_sets = [
        %{},
        %{foo: :bar},
        %{baz: :quux}
      ]

      for metric <- metrics, tags <- tags_sets do
        %{size: size_before, memory: mem_before} = Peep.storage_size(name)
        Peep.Test.insert_metric(name, metric, 5, tags)
        %{size: size_after, memory: mem_after} = Peep.storage_size(name)

        assert size_after > size_before
        assert mem_after > mem_before
      end
    end

    test "#{inspect(impl)} - pruning every inserted tags map empties storage" do
      metrics = prune_metrics()

      check(unquote(impl),
        metrics: metrics,
        inserts: prune_inserts(metrics),
        prune: [%{foo: :bar}, %{baz: :quux}],
        exp_scrape: %{}
      )
    end

    test "#{inspect(impl)} - a pattern matching no tags map prunes nothing" do
      metrics = prune_metrics()

      check(unquote(impl),
        metrics: metrics,
        inserts: prune_inserts(metrics),
        prune: [%{foo: :bar, baz: :quux}],
        exp_scrape: pruned_scrape(metrics, [%{foo: :bar}, %{baz: :quux}])
      )
    end

    test "#{inspect(impl)} - patterns matching nothing don't stop the others" do
      metrics = prune_metrics()

      check(unquote(impl),
        metrics: metrics,
        inserts: prune_inserts(metrics),
        prune: [%{foo: :blah}, %{foo: :bar}],
        exp_scrape: pruned_scrape(metrics, [%{baz: :quux}])
      )
    end
  end

  defp check(impl, opts) do
    name = Peep.Test.start_peep!(storage: impl, metrics: Keyword.fetch!(opts, :metrics))
    inserts = Keyword.fetch!(opts, :inserts)

    insert = fn ->
      for {metric, value, tags} <- inserts do
        Peep.Test.insert_metric(name, metric, value, tags)
      end
    end

    case Keyword.get(opts, :tasks, 1) do
      1 -> insert.()
      tasks -> 1..tasks |> Enum.map(fn _ -> Task.async(insert) end) |> Task.await_many()
    end

    if patterns = opts[:prune] do
      assert Peep.prune_tags(name, patterns) == :ok
    end

    assert Peep.get_all_metrics(name) == Keyword.fetch!(opts, :exp_scrape)
  end

  defp prune_metrics do
    [
      Metrics.counter("storage.test.counter"),
      Metrics.sum("storage.test.sum"),
      Metrics.last_value("storage.test.gauge"),
      Metrics.distribution("storage.test.distribution", reporter_options: [max_value: 1000])
    ]
  end

  defp prune_inserts(metrics) do
    for metric <- metrics, tags <- [%{foo: :bar}, %{baz: :quux}], do: {metric, 5, tags}
  end

  # The scrape after `prune_inserts/1`, keeping only the series under `tags`.
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
end
