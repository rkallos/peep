defmodule Peep.Storage.Test do
  @moduledoc """
  Sets up Storage backend test cases.

  ## Usage

  To test one or more Storage backends, set the `:test_storages` on the `:peep`
  configuration and require this file, ie:

  # your_storage_test.exs
  Application.put_env(:peep, :test_storages, [{CustomStorage, 3}, {OtherStorage, []}])
  Code.require_file "../deps/peep/test/shared/storage_test.exs", __DIR__

  """

  use ExUnit.Case, async: true

  alias Telemetry.Metrics

  @impls Application.compile_env(:peep, :test_storages)

  for impl <- @impls do
    test "#{inspect(impl)} - a counter can be stored and retrieved" do
      counter = Metrics.counter("storage.test.counter")

      name = start_peep!(storage: unquote(impl), metrics: [counter])

      f = fn ->
        for i <- 1..10 do
          Peep.insert_metric(name, counter, 1, %{})

          if rem(i, 2) == 0 do
            Peep.insert_metric(name, counter, 1, %{even: true})
          end
        end
      end

      1..100 |> Enum.map(fn _ -> Task.async(f) end) |> Task.await_many()

      assert Peep.get_metric(name, counter, %{}) == 1000
      assert Peep.get_metric(name, counter, %{even: true}) == 500
    end

    test "#{inspect(impl)} - a sum can be stored and retrieved" do
      sum = Metrics.sum("storage.test.sum")

      name = start_peep!(storage: unquote(impl), metrics: [sum])

      f = fn ->
        for i <- 1..10 do
          Peep.insert_metric(name, sum, 2, %{})

          if rem(i, 2) == 0 do
            Peep.insert_metric(name, sum, 3, %{even: true})
          end
        end
      end

      1..100 |> Enum.map(fn _ -> Task.async(f) end) |> Task.await_many()

      assert Peep.get_metric(name, sum, []) == 100 * 20
      assert Peep.get_metric(name, sum, even: true) == 100 * 15
    end

    test "#{inspect(impl)} - a last_value can be stored and retrieved" do
      last_value = Metrics.last_value("storage.test.gauge")

      name = start_peep!(storage: unquote(impl), metrics: [last_value])

      f = fn ->
        for i <- 1..10 do
          Peep.insert_metric(name, last_value, i, %{})

          if rem(i, 2) == 1 do
            Peep.insert_metric(name, last_value, i, %{odd: true})
          end
        end
      end

      1..100 |> Enum.map(fn _ -> Task.async(f) end) |> Task.await_many()

      assert Peep.get_metric(name, last_value, []) == 10
      assert Peep.get_metric(name, last_value, odd: true) == 9
    end

    test "#{inspect(impl)} - a distribution can be stored and retrieved" do
      dist =
        Metrics.distribution("storage.test.distribution", reporter_options: [max_value: 1000])

      name = start_peep!(storage: unquote(impl), metrics: [dist])

      f = fn ->
        for i <- 0..2000 do
          Peep.insert_metric(name, dist, i, %{})
        end
      end

      1..100 |> Enum.map(fn _ -> Task.async(f) end) |> Task.await_many()

      expected = %{
        "1.0" => 100 * 2,
        "1.222222" => 0,
        "1.493827" => 0,
        "1.825789" => 0,
        "2.727413" => 0,
        "2.23152" => 100,
        "3.333505" => 100,
        "4.074283" => 100,
        "4.97968" => 0,
        "6.086275" => 100 * 2,
        "7.438781" => 100,
        "9.091843" => 100 * 2,
        "11.112253" => 100 * 2,
        "13.581642" => 100 * 2,
        "16.599785" => 100 * 3,
        "20.288626" => 100 * 4,
        "24.79721" => 100 * 4,
        "30.307701" => 100 * 6,
        "37.042745" => 100 * 7,
        "45.274466" => 100 * 8,
        "55.335459" => 100 * 10,
        "67.632227" => 100 * 12,
        "82.661611" => 100 * 15,
        "101.030858" => 100 * 19,
        "123.48216" => 100 * 22,
        "150.92264" => 100 * 27,
        "184.461004" => 100 * 34,
        "225.452339" => 100 * 41,
        "275.552858" => 100 * 50,
        "336.786827" => 100 * 61,
        "411.628344" => 100 * 75,
        "503.101309" => 100 * 92,
        "614.9016" => 100 * 111,
        "751.5464" => 100 * 137,
        "918.556711" => 100 * 167,
        "1122.680424" => 100 * 204,
        :infinity => 100 * 878,
        :sum => 100 * 2_001_000
      }

      assert Peep.get_metric(name, dist, []) == expected
    end

    test "#{inspect(impl)} - distribution bucket variability" do
      dist =
        Metrics.distribution("storage.test.distribution",
          reporter_options: [
            max_value: 1000,
            bucket_variability: 0.25
          ]
        )

      name = start_peep!(storage: unquote(impl), metrics: [dist])

      f = fn ->
        for i <- 0..1000 do
          Peep.insert_metric(name, dist, i, %{})
        end
      end

      1..100 |> Enum.map(fn _ -> Task.async(f) end) |> Task.await_many()

      expected = %{
        "1.0" => 2 * 100,
        "1.666667" => 0,
        "2.777778" => 100,
        "4.62963" => 2 * 100,
        "7.716049" => 3 * 100,
        "12.860082" => 5 * 100,
        "21.433471" => 9 * 100,
        "35.722451" => 14 * 100,
        "59.537418" => 24 * 100,
        "99.22903" => 40 * 100,
        "165.381717" => 66 * 100,
        "275.636195" => 110 * 100,
        "459.393658" => 184 * 100,
        "765.656097" => 306 * 100,
        "1276.093494" => 235 * 100,
        :infinity => 0,
        :sum => 500_500 * 100
      }

      assert Peep.get_metric(name, dist, []) == expected
    end

    test "#{inspect(impl)} - default distribution handles negative values" do
      dist =
        Metrics.distribution("storage.test.distribution",
          reporter_options: [
            max_value: 500,
            bucket_variability: 0.25
          ]
        )

      name = start_peep!(storage: unquote(impl), metrics: [dist])

      f = fn ->
        for i <- -500..500 do
          Peep.insert_metric(name, dist, i, %{})
        end
      end

      1..100 |> Enum.map(fn _ -> Task.async(f) end) |> Task.await_many()

      expected = %{
        "1.0" => 502 * 100,
        "1.666667" => 0,
        "2.777778" => 100,
        "4.62963" => 2 * 100,
        "7.716049" => 3 * 100,
        "12.860082" => 5 * 100,
        "21.433471" => 9 * 100,
        "35.722451" => 14 * 100,
        "59.537418" => 24 * 100,
        "99.22903" => 40 * 100,
        "165.381717" => 66 * 100,
        "275.636195" => 110 * 100,
        "459.393658" => 184 * 100,
        "765.656097" => 41 * 100,
        :infinity => 0,
        :sum => 0
      }

      assert Peep.get_metric(name, dist, []) == expected
    end

    test "#{inspect(impl)} - storage_size/1" do
      counter = Metrics.counter("storage.test.counter")
      sum = Metrics.sum("storage.test.sum")
      last_value = Metrics.last_value("storage.test.gauge")

      dist =
        Metrics.distribution("storage.test.distribution", reporter_options: [max_value: 1000])

      metrics = [counter, sum, last_value, dist]

      name = start_peep!(storage: unquote(impl), metrics: metrics)

      tags_sets = [
        %{},
        %{foo: :bar},
        %{baz: :quux}
      ]

      for metric <- metrics, tags <- tags_sets do
        %{size: size_before, memory: mem_before} = Peep.storage_size(name)
        Peep.insert_metric(name, metric, 5, tags)
        %{size: size_after, memory: mem_after} = Peep.storage_size(name)

        assert size_after > size_before
        assert mem_after > mem_before
      end
    end

    test "#{inspect(impl)} - prune tags" do
      counter = Metrics.counter("storage.test.counter")
      sum = Metrics.sum("storage.test.sum")
      last_value = Metrics.last_value("storage.test.gauge")

      dist =
        Metrics.distribution("storage.test.distribution", reporter_options: [max_value: 1000])

      metrics = [counter, sum, last_value, dist]

      name = start_peep!(storage: unquote(impl), metrics: metrics)

      populate = fn ->
        for metric <- metrics do
          Peep.insert_metric(name, metric, 5, %{foo: :bar})
          Peep.insert_metric(name, metric, 5, %{baz: :quux})
        end

        assert Peep.get_all_metrics(name) != %{}
      end

      populate.()
      assert Peep.prune_tags(name, [%{foo: :bar}, %{baz: :quux}]) == :ok
      assert Peep.get_all_metrics(name) == %{}

      populate.()
      assert Peep.prune_tags(name, [%{foo: :bar, baz: :quux}]) == :ok
      assert Peep.get_all_metrics(name) != %{}

      populate.()
      assert Peep.prune_tags(name, [%{foo: :blah}, %{foo: :bar}, %{baz: :quux}]) == :ok
      assert Peep.get_all_metrics(name) == %{}
    end
  end

  defp start_peep!(options) do
    name = System.unique_integer([:positive]) |> Integer.to_string() |> String.to_atom()

    {:ok, _pid} = Peep.start_link(Keyword.put(options, :name, name))
    name
  end
end
