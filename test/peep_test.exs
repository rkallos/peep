defmodule PeepTest do
  use ExUnit.Case
  doctest Peep

  test "greets the world" do
    assert Peep.hello() == :world
  end
end
