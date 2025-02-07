defmodule Peep.Storage do
  alias Telemetry.Metrics

  @callback new() :: term()
  @callback storage_size(term()) :: %{size: non_neg_integer(), memory: non_neg_integer()}
  @callback insert_metric(term(), Metrics.t(), term(), map()) :: any()
  @callback get_all_metrics(term()) :: map()
  @callback get_metric(term(), Metrics.t(), map()) :: any()

  @doc """
  Removes metrics whose metadata contains a specific tag key and value.
  This is intended to improve situations where Peep emits metrics whose tags
  have high cardinality.
  """
  @callback prune_tags(Enumerable.t(%{Metrics.tag() => term()}), map()) :: :ok
end
