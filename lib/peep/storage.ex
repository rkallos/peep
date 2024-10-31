defmodule Peep.Storage do
  alias Telemetry.Metrics

  @callback new() :: term()
  @callback storage_size(term()) :: %{size: non_neg_integer(), memory: non_neg_integer()}
  @callback insert_metric(term(), Metrics.t(), term(), map()) :: any()
  @callback get_all_metrics(term()) :: map()
  @callback get_metric(term(), Metrics.t(), map()) :: any()
end
