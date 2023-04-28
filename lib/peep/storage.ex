defmodule Peep.Storage do
  alias Telemetry.Metrics

  @spec new(atom, float) :: :ets.tid()
  def new(name, alpha \\ 0.10) do
    tid = :ets.new(name, [:public, :named_table])
    gamma = (1 + alpha) / (1 - alpha)
    :ets.insert(name, {:gamma, gamma})
    denominator = :math.log(gamma)
    :ets.insert(name, {:denominator, denominator})
    tid
  end

  def insert_metric(tid, %Metrics.Counter{} = metric, _value, tags) do
    key = {metric, tags}
    :ets.update_counter(tid, key, {2, 1}, {key, 0})
  end

  def insert_metric(tid, %Metrics.Sum{} = metric, value, tags) do
    key = {metric, tags}
    :ets.update_counter(tid, key, {2, value}, {key, 0})
  end

  def insert_metric(tid, %Metrics.LastValue{} = metric, value, tags) do
    key = {metric, tags}
    :ets.insert(tid, {key, value})
  end

  def insert_metric(tid, %Metrics.Distribution{} = metric, value, tags) do
    bucket = calculate_bucket(tid, value)
    bucket_key = {metric, tags, bucket}
    sum_key = {metric, tags, :sum}
    :ets.update_counter(tid, bucket_key, {2, 1}, {bucket_key, 0})
    :ets.update_counter(tid, sum_key, {2, round(value)}, {sum_key, 0})
  end

  def get_all_metrics(tid) do
    :ets.tab2list(tid)
    |> group_metrics(tid)
  end

  def get_metric(tid, %Metrics.Counter{} = metric, tags) do
    case :ets.lookup(tid, {metric, tags}) do
      [{_key, count}] -> count
      _ -> nil
    end
  end

  def get_metric(tid, %Metrics.Sum{} = metric, tags) do
    case :ets.lookup(tid, {metric, tags}) do
      [{_key, count}] -> count
      _ -> nil
    end
  end

  def get_metric(tid, %Metrics.LastValue{} = metric, tags) do
    case :ets.lookup(tid, {metric, tags}) do
      [{_key, value}] -> value
      _ -> nil
    end
  end

  def get_metric(tid, %Metrics.Distribution{} = metric, tags) do
    gamma = gamma(tid)

    case :ets.match(tid, {{metric, tags, :"$1"}, :"$2"}) do
      [] ->
        nil

      matches ->
        for [bucket_idx, count] <- matches, into: %{} do
          {bucket_idx_to_upper_bound(bucket_idx, gamma), count}
        end
    end
  end

  defp calculate_bucket(_tid, 0) do
    0
  end

  defp calculate_bucket(tid, value) do
    ceil(:math.log(value) / denominator(tid))
  end

  defp group_metrics(metrics, tid), do: group_metrics(metrics, %{}, gamma(tid))

  defp group_metrics([], acc, _gamma), do: acc

  defp group_metrics([{:denominator, _} | rest], acc, gamma) do
    group_metrics(rest, acc, gamma)
  end

  defp group_metrics([{:gamma, _} | rest], acc, gamma) do
    group_metrics(rest, acc, gamma)
  end

  defp group_metrics([metric | rest], acc, gamma) do
    acc2 = group_metric(metric, acc, gamma)
    group_metrics(rest, acc2, gamma)
  end

  defp group_metric({{%Metrics.Counter{} = metric, tags}, value}, acc, _gamma) do
    inner_map =
      Map.get(acc, metric, %{})
      |> Map.put_new(tags, value)

    Map.put(acc, metric, inner_map)
  end

  defp group_metric({{%Metrics.Sum{} = metric, tags}, value}, acc, _gamma) do
    inner_map =
      Map.get(acc, metric, %{})
      |> Map.put_new(tags, value)

    Map.put(acc, metric, inner_map)
  end

  defp group_metric({{%Metrics.LastValue{} = metric, tags}, value}, acc, _gamma) do
    inner_map =
      Map.get(acc, metric, %{})
      |> Map.put_new(tags, value)

    Map.put(acc, metric, inner_map)
  end

  defp group_metric({{%Metrics.Distribution{} = metric, tags, bucket_idx}, count}, acc, gamma) do
    dist_map = Map.get(acc, metric, %{})

    tags_map =
      Map.get(dist_map, tags, %{})
      |> Map.put_new(bucket_idx_to_upper_bound(bucket_idx, gamma), count)

    Map.put(acc, metric, Map.put(dist_map, tags, tags_map))
  end

  defp bucket_idx_to_upper_bound(idx, gamma) do
    case idx do
      :sum -> :sum
      _ -> format_bucket_upper_bound(gamma ** idx)
    end
  end

  defp format_bucket_upper_bound(ub) do
    :erlang.float_to_binary(ub, [:compact, {:decimals, 6}])
  end

  defp denominator(tid) do
    [{:denominator, d}] = :ets.lookup(tid, :denominator)
    d
  end

  defp gamma(tid) do
    [{:gamma, g}] = :ets.lookup(tid, :gamma)
    g
  end
end
