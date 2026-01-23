defmodule CustomStorage do
  @moduledoc """
  Custom implementation of Peep.Storage for testing purposes.
  Uses multiple agents which hold a simple map each with the metrics.
  The number of agents is an option passed to new/1.
  The agent is picked based on a random number.
  """
  @behaviour Peep.Storage

  alias Telemetry.Metrics
  alias Peep.Storage

  @impl true
  @spec new(non_neg_integer) :: tuple
  def new(n_agents) do
    for _ <- 1..n_agents do
      {:ok, pid} = Agent.start_link(fn -> %{} end)
      pid
    end
    |> List.to_tuple()
  end

  @impl true
  def storage_size(agents) when is_tuple(agents) do
    {total_size, total_memory} =
      agents
      |> Tuple.to_list()
      |> Enum.reduce({0, 0}, fn agent, {size_acc, mem_acc} ->
        map = Agent.get(agent, & &1)
        size = map_size(map)
        memory = :erlang.external_size(map)

        {size_acc + size, mem_acc + memory}
      end)

    %{size: total_size, memory: total_memory}
  end

  @impl true
  def insert_metric(agents, id, %Metrics.Counter{}, _value, %{} = tags) do
    agent = pick_agent(agents)
    key = {id, tags}

    Agent.update(agent, fn state ->
      Map.update(state, key, 1, &(&1 + 1))
    end)
  end

  def insert_metric(agents, id, %Metrics.Sum{}, value, %{} = tags) do
    agent = pick_agent(agents)
    key = {id, tags}

    Agent.update(agent, fn state ->
      Map.update(state, key, value, &(&1 + value))
    end)
  end

  def insert_metric(agents, id, %Metrics.LastValue{}, value, %{} = tags) do
    agent = pick_agent(agents)
    key = {id, tags}

    Agent.update(agent, fn state ->
      Map.put(state, key, value)
    end)
  end

  def insert_metric(agents, id, %Metrics.Distribution{} = metric, value, %{} = tags) do
    agent = pick_agent(agents)
    key = {id, tags}

    Agent.get_and_update(agent, fn state ->
      atomics =
        case Map.get(state, key) do
          nil ->
            Storage.Atomics.new(metric)

          existing ->
            existing
        end

      Storage.Atomics.insert(atomics, value)

      {:ok, Map.put(state, key, atomics)}
    end)
  end

  @impl true
  def get_all_metrics(agents, %Peep.Persistent{ids_to_metrics: itm}) do
    agents
    |> Tuple.to_list()
    |> Enum.flat_map(fn agent ->
      Agent.get(agent, &Map.to_list/1)
    end)
    |> group_metrics(itm, %{})
  end

  @impl true
  def get_metric(agents, id, %Metrics.Counter{}, tags) do
    key = {id, tags}

    for agent <- Tuple.to_list(agents), reduce: 0 do
      acc -> acc + Agent.get(agent, &Map.get(&1, key, 0))
    end
  end

  def get_metric(agents, id, %Metrics.Sum{}, tags) do
    key = {id, tags}

    for agent <- Tuple.to_list(agents), reduce: 0 do
      acc -> acc + Agent.get(agent, &Map.get(&1, key, 0))
    end
  end

  def get_metric(agents, id, %Metrics.LastValue{}, tags) do
    key = {id, tags}

    for agent <- Tuple.to_list(agents), reduce: nil do
      acc ->
        case Agent.get(agent, &Map.get(&1, key)) do
          nil ->
            acc

          value ->
            if acc do
              max(value, acc)
            else
              value
            end
        end
    end
  end

  def get_metric(agents, id, %Metrics.Distribution{}, tags) do
    key = {id, tags}

    merge_fun = fn _k, v1, v2 -> v1 + v2 end

    for agent <- Tuple.to_list(agents), reduce: nil do
      acc ->
        case Agent.get(agent, &Map.get(&1, key)) do
          nil ->
            acc

          atomics ->
            values = Storage.Atomics.values(atomics)

            if acc do
              Map.merge(acc, values, merge_fun)
            else
              values
            end
        end
    end
  end

  @impl true
  def prune_tags(agents, patterns) do
    agents
    |> Tuple.to_list()
    |> Enum.each(fn agent ->
      Agent.update(agent, fn state ->
        prune_agent_state(state, patterns)
      end)
    end)

    :ok
  end

  # Private functions

  defp pick_agent(agents) do
    size = tuple_size(agents)
    index = :rand.uniform(size) - 1
    elem(agents, index)
  end

  defp prune_agent_state(state, patterns) do
    Enum.reduce(state, state, fn {key, _value}, acc ->
      if should_prune?(key, patterns) do
        Map.delete(acc, key)
      else
        acc
      end
    end)
  end

  defp should_prune?({_id, tags}, patterns) when is_map(tags) do
    Enum.any?(patterns, fn pattern ->
      tags_match?(tags, pattern)
    end)
  end

  defp should_prune?(_key, _patterns), do: false

  defp tags_match?(tags, pattern) do
    Enum.all?(pattern, fn {key, value} ->
      Map.get(tags, key) == value
    end)
  end

  defp group_metrics([], _itm, acc), do: acc

  defp group_metrics([metric | rest], itm, acc) do
    acc2 = group_metric(metric, itm, acc)
    group_metrics(rest, itm, acc2)
  end

  defp group_metric({{id, tags}, %Storage.Atomics{} = atomics}, itm, acc) do
    %{^id => metric} = itm
    put_in(acc, [Access.key(metric, %{}), Access.key(tags)], Storage.Atomics.values(atomics))
  end

  defp group_metric({{id, tags}, value}, itm, acc) do
    %{^id => metric} = itm

    case metric do
      %Metrics.Counter{} ->
        update_in(acc, [Access.key(metric, %{}), Access.key(tags, 0)], &(&1 + value))

      %Metrics.Sum{} ->
        update_in(acc, [Access.key(metric, %{}), Access.key(tags, 0)], &(&1 + value))

      _ ->
        put_in(acc, [Access.key(metric, %{}), Access.key(tags)], value)
    end
  end
end
