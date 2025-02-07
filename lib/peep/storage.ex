defmodule Peep.Storage do
  @moduledoc """
  Behaviour for Peep storage backends. These functions are mainly called by Peep
  during normal functioning. Ordinary usage of Peep should not require calling
  any of these functions.
  """
  alias Telemetry.Metrics

  @doc """
  Creates a new term representing a Peep storage backend.
  """
  @callback new() :: term()

  @doc """
  Calculates the amount of memory used by a Peep storage backend.
  """
  @callback storage_size(term()) :: %{size: non_neg_integer(), memory: non_neg_integer()}

  @doc """
  Stores a sample metric
  """
  @callback insert_metric(term(), Metrics.t(), term(), map()) :: any()

  @doc """
  Retrieves all stored metrics
  """
  @callback get_all_metrics(term()) :: map()

  @doc """
  Retrieves a single stored metric
  """
  @callback get_metric(term(), Metrics.t(), map()) :: any()

  @doc """
  Removes metrics whose metadata contains a specific tag key and value.
  This is intended to improve situations where Peep emits metrics whose tags
  have high cardinality.
  """
  @callback prune_tags(Enumerable.t(%{Metrics.tag() => term()}), map()) :: :ok
end
