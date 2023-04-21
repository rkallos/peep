defmodule PeepTest do
  use ExUnit.Case
  doctest Peep

  test "a worker can be started" do
    options = [
      name: __MODULE__,
      metrics: []
    ]

    assert {:ok, pid} = Peep.start_link(options)
    assert Process.alive?(pid)
  end

  test "many workers can be started" do
    for i <- 1..10 do
      options = [
        name: :"#{__MODULE__}_#{i}",
        metrics: []
      ]

      assert {:ok, pid} = Peep.start_link(options)
      assert Process.alive?(pid)
    end
  end
end
