defmodule Peep.Buckets do
  @default_module Peep.Buckets.Exponential
  @reporter_option :peep_bucket_calculator

  @moduledoc """
  A behavior for histogram bucketing strategies.

  If no bucketing strategy is provided (i.e. #{@reporter_option} is not set in
  :reporter_options for a `%Telemetry.Metrics.Distribution{}`, then the default
  is `#{@default_module}`.

  If you want custom bucket boundaries, there is `Peep.Buckets.Custom`, which
  uses pattern matching to assign sample measurements to buckets.
  """

  alias Telemetry.Metrics

  @type config :: map

  @callback config(Metrics.Distribution.t()) :: config
  @callback number_of_buckets(config) :: pos_integer
  @callback bucket_for(number, config) :: non_neg_integer
  @callback upper_bound(non_neg_integer, config) :: String.t()

  @spec config(Metrics.Distribution.t()) :: {atom, config}
  def config(%Metrics.Distribution{reporter_options: opts} = metric) do
    module = Keyword.get(opts, @reporter_option, @default_module)
    {module, module.config(metric)}
  end
end
