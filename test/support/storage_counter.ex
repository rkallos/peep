defmodule Peep.Support.StorageCounter do
  @moduledoc false

  def fresh_id() do
    :"#{System.unique_integer([:positive])}"
  end
end
