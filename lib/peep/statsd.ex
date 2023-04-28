defmodule Peep.Statsd do
  @moduledoc false
  require Logger

  alias Peep.Statsd.{Cache, Packet}
  alias Peep.Telemetry

  defstruct prev: Cache.new([]), statsd_opts: %{}, socket: nil

  def make_state(statsd_opts) do
    %__MODULE__{statsd_opts: statsd_opts}
    |> try_to_open_socket()
  end

  def make_and_send_packets(metrics, state) do
    prepare(metrics, state)
    |> send_packets(try_to_open_socket(state))
  end

  def prepare(metrics, %__MODULE__{prev: prev, statsd_opts: statsd_opts}) do
    cache = Cache.new(metrics)
    deltas = Cache.calculate_deltas(cache, prev)
    lines = make_lines(deltas, statsd_opts[:formatter] || :standard)
    packets = fill_packets(lines, statsd_opts[:mtu] || 1472)
    {cache, packets}
  end

  defp send_packets({cache, packets}, state) do
    send_packets(packets, cache, state)
  end

  defp fill_packets(metrics, mtu) do
    fill_packets(metrics, mtu, [Packet.new(mtu)])
  end

  defp fill_packets([], _mtu, packets) do
    Enum.reverse(packets)
  end

  defp fill_packets(
         [{key, line} | rest],
         mtu,
         [packet | packets]
       ) do
    new_acc =
      if Packet.can_add?(packet, line) do
        new_packet = Packet.add(packet, key, line)
        [new_packet | packets]
      else
        new_packet = Packet.new(mtu) |> Packet.add(key, line)
        [new_packet, packet | packets]
      end

    fill_packets(rest, mtu, new_acc)
  end

  defp send_packets([], _cache, state) do
    state
  end

  defp send_packets(_packets, _cache, %__MODULE__{socket: nil} = state) do
    state
  end

  defp send_packets(
         [packet | rest],
         cache,
         %__MODULE__{prev: prev, statsd_opts: opts, socket: socket} = state
       ) do
    {packet_size, result} = Packet.send(packet, socket, opts)

    Telemetry.sent_packet(packet_size, result)

    new_state =
      case result do
        :ok ->
          %__MODULE__{state | prev: Cache.replace(prev, packet.keys, cache)}

        {:error, :eagain} ->
          state

        {:error, :emsgsize} ->
          length = IO.iodata_length(packet.lines)
          new_mtu = min(opts[:mtu], length) - 1
          new_opts = Keyword.put(opts, :mtu, new_mtu)
          %__MODULE__{state | statsd_opts: new_opts}

        {:error, _reason} ->
          %__MODULE__{state | socket: nil}
      end

    send_packets(rest, cache, new_state)
  end

  defp make_lines(kv, formatter) do
    for {key, value} <- kv do
      {key, format_line(key, value, formatter)}
    end
  end

  defp format_line({:counter, name, tags}, count, _formatter) do
    [name, ?:, n2b(count), "|c", tags]
  end

  defp format_line({:last_value, name, tags}, value, _formatter) do
    [name, ?:, n2b(value), "|g", tags]
  end

  defp format_line({:sum, name, tags}, sum, _formatter) do
    [name, ?:, n2b(sum), "|c", tags]
  end

  defp format_line({:dist, name, tags, bucket}, count, formatter) do
    type_bytes =
      case formatter do
        :datadog -> ?d
        _ -> "ms"
      end

    [name, ?:, to_string(bucket), ?|, type_bytes, "|@", f2b(1.0 / count), tags]
  end

  defp f2b(f), do: :erlang.float_to_binary(f, [:compact, {:decimals, 6}])
  defp n2b(n) when is_integer(n), do: :erlang.integer_to_binary(n)
  defp n2b(n) when is_float(n), do: :erlang.float_to_binary(n, [:compact, {:decimals, 2}])

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
