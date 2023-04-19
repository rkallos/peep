defmodule Peep.Statsd do
  require Logger
  alias Telemetry.Metrics.{Counter, Distribution, LastValue, Sum}

  defmodule Packet do
    defstruct metrics: [], lines: [], remaining: nil

    def new(mtu) do
      %Packet{remaining: mtu}
    end

    def can_add_metric_lines?(%Packet{remaining: remaining}, new_lines) do
      remaining - calculate_byte_size(new_lines) >= 0
    end

    def add_metric_lines(
          %Packet{metrics: metrics, lines: lines, remaining: remaining} = packet,
          new_metric,
          new_lines
        ) do
      %Packet{
        packet
        | metrics: [new_metric | metrics],
          lines: [Enum.intersperse(new_lines, ?\n), ?\n | lines],
          remaining: remaining - calculate_byte_size(new_lines)
      }
    end

    def send(%Packet{lines: data}, socket, statsd_opts) do
      host = statsd_opts[:host]

      port =
        if match?({:local, _}, host) do
          0
        else
          statsd_opts[:port]
        end

      case :gen_udp.send(socket, host, port, data) do
        :ok ->
          :ok

        {:error, reason} = err ->
          Logger.error("unable to emit StatsD metrics. reason: #{inspect(reason)}")
          err
      end
    end

    defp calculate_byte_size(lines) do
      bytes = IO.iodata_length(lines)
      newlines = length(lines) + 1
      bytes + newlines
    end
  end

  defstruct prev: %{}, statsd_opts: %{}, socket: nil

  def make_state(statsd_opts) do
    %__MODULE__{statsd_opts: statsd_opts}
    |> try_to_open_socket()
  end

  def make_and_send_packets(metrics, %__MODULE__{prev: prev, statsd_opts: statsd_opts} = state) do
    metrics
    |> calculate_deltas(prev)
    |> make_lines(statsd_opts[:formatter])
    |> make_packets(statsd_opts[:mtu])
    |> send_packets(try_to_open_socket(state))
  end

  def make_packets(metrics, mtu) do
    make_packets(metrics, mtu, [Packet.new(mtu)])
  end

  defp make_packets([], _mtu, packets) do
    Enum.reverse(packets)
  end

  defp make_packets(
         [{metric, lines} | rest],
         mtu,
         [packet | packets]
       ) do
    new_acc =
      if Packet.can_add_metric_lines?(packet, lines) do
        new_packet = Packet.add_metric_lines(packet, metric, lines)
        [new_packet | packets]
      else
        new_packet = Packet.new(mtu) |> Packet.add_metric_lines(metric, lines)
        [new_packet, packet | packets]
      end

    make_packets(rest, mtu, new_acc)
  end

  defp send_packets([], state) do
    state
  end

  defp send_packets(_packets, %__MODULE__{socket: nil} = state) do
    state
  end

  defp send_packets(
         [packet | rest],
         %__MODULE__{prev: prev, statsd_opts: opts, socket: socket} = state
       ) do
    new_state =
      case Packet.send(packet, socket, opts) do
        :ok ->
          %__MODULE__{state | prev: Map.merge(prev, Enum.into(packet.metrics, %{}))}

        {:error, :eagain} ->
          state

        _ ->
          %__MODULE__{state | socket: nil}
      end

    send_packets(rest, new_state)
  end

  defp calculate_deltas(current_metrics, previous_metrics) do
    for {key, _tagged_series} = metric <- current_metrics, reduce: %{} do
      acc ->
        delta = calculate_delta(metric, previous_metrics)

        if delta != %{} do
          Map.put(acc, key, delta)
        else
          acc
        end
    end
  end

  defp calculate_delta({%Counter{} = metric, tagged_values}, previous_metrics) do
    previous_metric = previous_metrics[metric] || %{}

    for {tags, value} <- tagged_values, reduce: %{} do
      acc ->
        previous_value = previous_metric[tags] || 0
        delta = value - previous_value

        if delta != 0 do
          Map.put(acc, tags, delta)
        else
          acc
        end
    end
  end

  defp calculate_delta({%LastValue{}, tagged_values}, _previous_metrics) do
    for {tags, value} <- tagged_values, into: %{} do
      {tags, value}
    end
  end

  defp calculate_delta({%Sum{} = metric, tagged_values}, previous_metrics) do
    previous_metric = previous_metrics[metric] || %{}

    for {tags, value} <- tagged_values, reduce: %{} do
      acc ->
        previous_value = previous_metric[tags] || 0
        delta = value - previous_value

        if delta != 0 do
          Map.put(acc, tags, delta)
        else
          acc
        end
    end
  end

  defp calculate_delta({%Distribution{} = metric, tagged_buckets}, previous_metrics) do
    previous_metric = previous_metrics[metric] || %{}

    for {tags, buckets} <- tagged_buckets, into: %{} do
      previous_buckets = previous_metric[tags] || %{}

      bucket_deltas =
        for {bucket_value, count} <- Map.delete(buckets, :sum), reduce: %{} do
          bucket_acc ->
            previous_count = previous_buckets[bucket_value] || 0
            delta = count - previous_count

            if delta != 0 do
              Map.put(bucket_acc, bucket_value, delta)
            else
              bucket_acc
            end
        end

      {tags, bucket_deltas}
    end
  end

  def make_lines(metrics, formatter) do
    for metric <- metrics do
      {metric, format_metric(metric, formatter)}
    end
  end

  def format_metric({%Counter{} = metric, tagged_counts}, _formatter) do
    name = format_name(metric.name)

    Enum.map(tagged_counts, fn {tags, count} ->
      [name, ?:, n2b(count), "|c", format_tags(tags)]
    end)
  end

  def format_metric({%LastValue{} = metric, tagged_values}, _formatter) do
    name = format_name(metric.name)

    Enum.map(tagged_values, fn {tags, value} ->
      [name, ?:, n2b(value), "|g", format_tags(tags)]
    end)
  end

  def format_metric({%Sum{} = metric, tagged_sums}, _formatter) do
    name = format_name(metric.name)

    Enum.map(tagged_sums, fn {tags, sum} ->
      [name, ?:, n2b(sum), "|c", format_tags(tags)]
    end)
  end

  def format_metric({%Distribution{} = metric, tagged_buckets}, formatter) do
    name = format_name(metric.name)

    type_bytes =
      case formatter do
        :datadog -> ?d
        _ -> "ms"
      end

    Enum.flat_map(tagged_buckets, fn {tags, buckets} ->
      tags_bytes = format_tags(tags)

      buckets
      |> Enum.map(fn {bucket_string, count} ->
        {bucket(bucket_string), count}
      end)
      |> Enum.sort()
      |> Enum.map(fn {bucket, count} ->
        [name, ?:, to_string(bucket), ?|, type_bytes, "|@", f2b(1.0 / count), tags_bytes]
      end)
    end)
  end

  defp format_name(segments) do
    Enum.map_intersperse(segments, ?., &a2b/1)
  end

  defp format_tags([]), do: ""

  defp format_tags(tags) do
    ["|#" | Enum.map_intersperse(tags, ?,, fn {k, v} -> [a2b(k), ?:, to_string(v)] end)]
  end

  defp a2b(a), do: :erlang.atom_to_binary(a, :utf8)
  defp f2b(f), do: :erlang.float_to_binary(f, [:compact, {:decimals, 6}])
  defp n2b(n) when is_integer(n), do: :erlang.integer_to_binary(n)
  defp n2b(n) when is_float(n), do: :erlang.float_to_binary(n, [:compact, {:decimals, 2}])

  defp bucket(s) when is_binary(s), do: String.to_float(s)
  defp bucket(other), do: to_string(other)

  defp try_to_open_socket(%__MODULE__{statsd_opts: statsd_opts, socket: nil} = state) do
    default_socket_opts = [active: false]

    opts =
      case statsd_opts[:host] do
        {:local, _} ->
          [:local | default_socket_opts]

        _ ->
          default_socket_opts
      end

    case :gen_udp.open(0, opts) do
      {:ok, sock} ->
        %__MODULE__{state | socket: sock}

      {:error, reason} ->
        Logger.error("unable to open StatsD socket. reason: #{inspect(reason)}")
        state
    end
  end

  defp try_to_open_socket(state), do: state
end
