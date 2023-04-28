defmodule Peep.Support.StorageCounter do
  use Agent

  def start() do
    Agent.start(fn -> 0 end, name: __MODULE__)
  end

  def fresh_id() do
    Agent.get_and_update(__MODULE__, fn i -> {:"#{i}", i + 1} end)
  end
end
