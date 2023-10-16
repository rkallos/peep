defmodule Peep.Buckets.PowersOfTen do
  @moduledoc """
  An implementation of `Peep.Buckets`, using `Peep.Buckets.Custom`.
  """

  use Peep.Buckets.Custom,
    buckets: [
      10,
      100,
      1_000,
      10_000,
      100_000,
      1_000_000,
      10_000_000,
      100_000_000,
      1_000_000_000
    ]
end
