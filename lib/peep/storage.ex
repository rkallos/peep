defmodule Peep.Storage do
  alias Telemetry.Metrics

  @alpha 0.10
  @gamma (1 + @alpha) / (1 - @alpha)
  @denominator :math.log(@gamma)

  @spec new() :: :ets.tid()
  def new() do
    :ets.new(:ordered_set, [:public])
  end

  def insert_metric(tid, %Metrics.Counter{} = metric, value, tags) do
    key = {metric, tags}
    :ets.update_counter(tid, key, {2, value}, {key, 0})
  end

  def insert_metric(tid, %Metrics.LastValue{} = metric, value, tags) do
    key = {metric, tags}
    :ets.insert(tid, {key, value})
  end

  def insert_metric(tid, %Metrics.Distribution{} = metric, value, tags) do
    bucket = ceil(:math.log(value) / @denominator)
    bucket_key = {metric, tags, bucket}
    sum_key = {metric, tags, :sum}
    :ets.update_counter(tid, bucket_key, {2, 1}, {bucket_key, 0})
    :ets.update_counter(tid, sum_key, {2, round(value)}, {sum_key, 0})
  end

  def get_all_metrics(tid) do
    :ets.tab2list(tid)
    |> group_metrics()
  end

  def get_metric(tid, %Metrics.Counter{} = metric, tags) do
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
    case :ets.match(tid, {{metric, tags, :"$1"}, :"$2"}) do
      [] ->
        nil

      matches ->
        for [bucket_idx, count] <- matches, into: %{} do
          {bucket_idx_to_upper_bound(bucket_idx), count}
        end
    end
  end

  defp group_metrics(metrics), do: group_metrics(metrics, %{})

  defp group_metrics([], acc), do: acc

  defp group_metrics([{{%Metrics.Counter{} = metric, tags}, value} | rest], acc) do
    inner_map =
      Map.get(acc, metric, %{})
      |> Map.put_new(tags, value)

    group_metrics(rest, Map.put(acc, metric, inner_map))
  end

  defp group_metrics([{{%Metrics.LastValue{} = metric, tags}, value} | rest], acc) do
    inner_map =
      Map.get(acc, metric, %{})
      |> Map.put_new(tags, value)

    group_metrics(rest, Map.put(acc, metric, inner_map))
  end

  defp group_metrics([{{%Metrics.Distribution{} = metric, tags, bucket_idx}, count} | rest], acc) do
    dist_map = Map.get(acc, metric, %{})

    tags_map =
      Map.get(dist_map, tags, %{})
      |> Map.put_new(bucket_idx_to_upper_bound(bucket_idx), count)

    group_metrics(rest, Map.put(acc, metric, Map.put(dist_map, tags, tags_map)))
  end

  defp bucket_idx_to_upper_bound(idx) do
    case idx do
      :sum -> :sum
      _ -> format_bucket_upper_bound(@gamma ** idx)
    end
  end

  defp format_bucket_upper_bound(ub) do
    :erlang.float_to_binary(ub, [:compact, {:decimals, 6}])
  end
end
