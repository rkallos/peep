defmodule Peep.Statsd.Cache do
  @moduledoc false
  alias Telemetry.Metrics.{Counter, Distribution, LastValue, Sum}

  defstruct kv: %{}

  def new(metrics) do
    %__MODULE__{}
    |> add_metrics(metrics)
  end

  def calculate_deltas(%__MODULE__{kv: kv_new}, %__MODULE__{kv: kv_old}) do
    for {key, value} <- kv_new, reduce: %{} do
      acc ->
        case key do
          {:last_value, _name, _tags} ->
            Map.put(acc, key, value)

          _ ->
            delta = value - Map.get(kv_old, key, 0)

            if delta != 0 do
              Map.put(acc, key, delta)
            else
              acc
            end
        end
    end
  end

  def replace(%__MODULE__{kv: to} = cache, keys, %__MODULE__{kv: from}) do
    new_kv =
      for key <- keys, into: to do
        {key, Map.fetch!(from, key)}
      end

    %{cache | kv: new_kv}
  end

  defp add_metrics(cache, metrics) do
    for metric <- metrics, reduce: cache do
      acc -> add(acc, metric)
    end
  end

  defp add(%__MODULE__{kv: kv} = cache, {%Counter{name: name}, tagged_series}) do
    formatted_name = format_name(name)

    new_kv =
      for {tags, count} <- tagged_series, into: kv do
        formatted_tags = format_tags(tags)
        {{:counter, formatted_name, formatted_tags}, count}
      end

    %{cache | kv: new_kv}
  end

  defp add(%__MODULE__{kv: kv} = cache, {%LastValue{name: name}, tagged_series}) do
    formatted_name = format_name(name)

    new_kv =
      for {tags, value} <- tagged_series, into: kv do
        formatted_tags = format_tags(tags)
        {{:last_value, formatted_name, formatted_tags}, value}
      end

    %{cache | kv: new_kv}
  end

  defp add(%__MODULE__{kv: kv} = cache, {%Sum{name: name}, tagged_series}) do
    formatted_name = format_name(name)

    new_kv =
      for {tags, sum} <- tagged_series, into: kv do
        formatted_tags = format_tags(tags)
        {{:sum, formatted_name, formatted_tags}, sum}
      end

    %{cache | kv: new_kv}
  end

  defp add(%__MODULE__{kv: kv} = cache, {%Distribution{name: name}, tagged_series}) do
    formatted_name = format_name(name)

    new_kv =
      for {tags, buckets} <- tagged_series, reduce: kv do
        acc ->
          formatted_tags = format_tags(tags)

          to_add =
            for {bucket, count} <- buckets, bucket != :sum, bucket != "+Inf", into: %{} do
              formatted_bucket = to_string(bucket)
              {{:dist, formatted_name, formatted_tags, formatted_bucket}, count}
            end

          Map.merge(acc, to_add)
      end

    %{cache | kv: new_kv}
  end

  defp format_name(segments) do
    Enum.map_intersperse(segments, ?., &a2b/1)
  end

  defp format_tags([]), do: ""

  defp format_tags(tags) do
    ["|#" | Enum.map_intersperse(tags, ?,, fn {k, v} -> [a2b(k), ?:, to_string(v)] end)]
  end

  defp a2b(a), do: :erlang.atom_to_binary(a, :utf8)
end
