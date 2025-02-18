defmodule Storage.Test do
  use ExUnit.Case

  alias Telemetry.Metrics

  @impls [
    Peep.Storage.ETS,
    Peep.Storage.Striped,
    Peep.Storage.ETSPreHashed,
    Peep.Storage.StripedPreHashed
  ]

  for impl <- @impls do
    test "#{impl} - a counter can be stored and retrieved" do
      tids = unquote(impl).new()

      counter = Metrics.counter("storage.test.counter")

      f = fn ->
        for i <- 1..10 do
          unquote(impl).insert_metric(tids, counter, 1, %{})

          if rem(i, 2) == 0 do
            unquote(impl).insert_metric(tids, counter, 1, %{even: true})
          end
        end
      end

      1..100 |> Enum.map(fn _ -> Task.async(f) end) |> Task.await_many()

      assert unquote(impl).get_metric(tids, counter, %{}) == 1000
      assert unquote(impl).get_metric(tids, counter, %{even: true}) == 500
    end

    test "#{impl} - a sum can be stored and retrieved" do
      tid = unquote(impl).new()

      sum = Metrics.sum("storage.test.sum")

      f = fn ->
        for i <- 1..10 do
          unquote(impl).insert_metric(tid, sum, 2, %{})

          if rem(i, 2) == 0 do
            unquote(impl).insert_metric(tid, sum, 3, %{even: true})
          end
        end
      end

      1..100 |> Enum.map(fn _ -> Task.async(f) end) |> Task.await_many()

      assert unquote(impl).get_metric(tid, sum, []) == 100 * 20
      assert unquote(impl).get_metric(tid, sum, even: true) == 100 * 15
    end

    test "#{impl} - a last_value can be stored and retrieved" do
      tid = unquote(impl).new()

      last_value = Metrics.last_value("storage.test.gauge")

      f = fn ->
        for i <- 1..10 do
          unquote(impl).insert_metric(tid, last_value, i, %{})

          if rem(i, 2) == 1 do
            unquote(impl).insert_metric(tid, last_value, i, %{odd: true})
          end
        end
      end

      1..100 |> Enum.map(fn _ -> Task.async(f) end) |> Task.await_many()

      assert unquote(impl).get_metric(tid, last_value, []) == 10
      assert unquote(impl).get_metric(tid, last_value, odd: true) == 9
    end

    test "#{impl} - a distribution can be stored and retrieved" do
      tid = unquote(impl).new()

      dist =
        Metrics.distribution("storage.test.distribution", reporter_options: [max_value: 1000])

      f = fn ->
        for i <- 0..2000 do
          unquote(impl).insert_metric(tid, dist, i, %{})
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

      assert unquote(impl).get_metric(tid, dist, []) == expected
    end

    test "#{impl} - distribution bucket variability" do
      tid = unquote(impl).new()

      dist =
        Metrics.distribution("storage.test.distribution",
          reporter_options: [
            max_value: 1000,
            bucket_variability: 0.25
          ]
        )

      f = fn ->
        for i <- 0..1000 do
          unquote(impl).insert_metric(tid, dist, i, %{})
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

      assert unquote(impl).get_metric(tid, dist, []) == expected
    end

    test "#{impl} - default distribution handles negative values" do
      tid = unquote(impl).new()

      dist =
        Metrics.distribution("storage.test.distribution",
          reporter_options: [
            max_value: 500,
            bucket_variability: 0.25
          ]
        )

      f = fn ->
        for i <- -500..500 do
          unquote(impl).insert_metric(tid, dist, i, %{})
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

      assert unquote(impl).get_metric(tid, dist, []) == expected
    end

    test "#{impl} - storage_size/1" do
      storage = unquote(impl).new()

      counter = Metrics.counter("storage.test.counter")
      sum = Metrics.sum("storage.test.sum")
      last_value = Metrics.last_value("storage.test.gauge")

      dist =
        Metrics.distribution("storage.test.distribution", reporter_options: [max_value: 1000])

      metrics = [counter, sum, last_value, dist]

      tags_sets = [
        %{},
        %{foo: :bar},
        %{baz: :quux}
      ]

      for metric <- metrics, tags <- tags_sets do
        %{size: size_before, memory: mem_before} = unquote(impl).storage_size(storage)
        unquote(impl).insert_metric(storage, metric, 5, tags)
        %{size: size_after, memory: mem_after} = unquote(impl).storage_size(storage)

        assert size_after > size_before
        assert mem_after > mem_before
      end
    end

    test "#{impl} - prune tags" do
      impl = unquote(impl)
      storage = impl.new()

      counter = Metrics.counter("storage.test.counter")
      sum = Metrics.sum("storage.test.sum")
      last_value = Metrics.last_value("storage.test.gauge")

      dist =
        Metrics.distribution("storage.test.distribution", reporter_options: [max_value: 1000])

      metrics = [counter, sum, last_value, dist]

      populate = fn ->
        for metric <- metrics do
          impl.insert_metric(storage, metric, 5, %{foo: :bar})
          impl.insert_metric(storage, metric, 5, %{baz: :quux})
        end

        assert impl.get_all_metrics(storage) != %{}
      end

      populate.()
      assert impl.prune_tags(storage, [%{foo: :bar}, %{baz: :quux}]) == :ok
      assert impl.get_all_metrics(storage) == %{}

      populate.()
      assert impl.prune_tags(storage, [%{foo: :bar, baz: :quux}]) == :ok
      assert impl.get_all_metrics(storage) != %{}

      populate.()
      assert impl.prune_tags(storage, [%{foo: :blah}, %{foo: :bar}, %{baz: :quux}]) == :ok
      assert impl.get_all_metrics(storage) == %{}
    end
  end
end
