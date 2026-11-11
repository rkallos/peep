defmodule CustomBatchedStorage do
  @moduledoc """
  Custom implementation of Peep.Storage for testing purposes.
  Identical to CustomStorage, except that it implements insert_metrics/3
  instead of insert_metric/5.
  """
  @behaviour Peep.Storage

  @impl true
  defdelegate new(n_agents), to: CustomStorage

  @impl true
  defdelegate resolve(agents), to: CustomStorage

  @impl true
  defdelegate storage_size(agents), to: CustomStorage

  @impl true
  defdelegate get_all_metrics(agents, persistent), to: CustomStorage

  @impl true
  defdelegate prune_tags(agents, patterns), to: CustomStorage

  @impl true
  def insert_metrics(_agents, _tag_results, []), do: :ok

  def insert_metrics(agents, tag_results, [{id, metric, value, tag_idx} | rest]) do
    CustomStorage.insert_metric(agents, id, metric, value, elem(tag_results, tag_idx))
    insert_metrics(agents, tag_results, rest)
  end
end
