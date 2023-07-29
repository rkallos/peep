defmodule StorageTest do
  use ExUnit.Case

  alias Peep.Storage
  alias Telemetry.Metrics

  alias Peep.Support.StorageCounter

  test "a counter can be stored and retrieved" do
    tid = Storage.new(StorageCounter.fresh_id())

    counter = Metrics.counter("storage.test.counter")

    for i <- 1..10 do
      Storage.insert_metric(tid, counter, 1, [])

      if rem(i, 2) == 0 do
        Storage.insert_metric(tid, counter, 1, even: true)
      end
    end

    assert Storage.get_metric(tid, counter, []) == 10
    assert Storage.get_metric(tid, counter, even: true) == 5
  end

  test "a sum can be stored and retrieved" do
    tid = Storage.new(StorageCounter.fresh_id())

    sum = Metrics.sum("storage.test.sum")

    for i <- 1..10 do
      Storage.insert_metric(tid, sum, 2, [])

      if rem(i, 2) == 0 do
        Storage.insert_metric(tid, sum, 3, even: true)
      end
    end

    assert Storage.get_metric(tid, sum, []) == 20
    assert Storage.get_metric(tid, sum, even: true) == 15
  end

  test "a last_value can be stored and retrieved" do
    tid = Storage.new(StorageCounter.fresh_id())

    last_value = Metrics.last_value("storage.test.gauge")

    for i <- 1..10 do
      Storage.insert_metric(tid, last_value, i, [])

      if rem(i, 2) == 1 do
        Storage.insert_metric(tid, last_value, i, odd: true)
      end
    end

    assert Storage.get_metric(tid, last_value, []) == 10
    assert Storage.get_metric(tid, last_value, odd: true) == 9
  end

  test "a distribution can be stored and retrieved" do
    tid = Storage.new(StorageCounter.fresh_id())

    dist = Metrics.distribution("storage.test.distribution", reporter_options: [max_value: 1000])

    for i <- 0..2000 do
      Storage.insert_metric(tid, dist, i, [])
    end

    expected = %{
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

    assert Storage.get_metric(tid, dist, []) == expected
  end

  test "distribution bucket variability" do
    tid = Storage.new(StorageCounter.fresh_id(), 0.25)

    dist = Metrics.distribution("storage.test.distribution", reporter_options: [max_value: 1000])

    for i <- 0..1000 do
      Storage.insert_metric(tid, dist, i, [])
    end

    expected = %{
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

    assert Storage.get_metric(tid, dist, []) == expected
  end
end
