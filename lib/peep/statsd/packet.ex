defmodule Peep.Statsd.Packet do
  @moduledoc false
  alias __MODULE__
  require Logger

  defstruct keys: [], lines: [], remaining: nil, max_size: nil

  def new(mtu) do
    %Packet{remaining: mtu, max_size: mtu}
  end

  def can_add?(%Packet{remaining: remaining}, data) do
    remaining - calculate_byte_size(data) >= 0
  end

  def add(
        %Packet{keys: keys, lines: lines, remaining: remaining} = packet,
        key,
        line
      ) do
    %Packet{
      packet
      | keys: [key | keys],
        lines: [line, ?\n | lines],
        remaining: remaining - calculate_byte_size(line)
    }
  end

  def send(%Packet{lines: data, remaining: remaining, max_size: max_size}, socket, statsd_opts) do
    host = statsd_opts[:host]

    port =
      if match?({:local, _}, host) do
        0
      else
        statsd_opts[:port]
      end

    packet_size = max_size - remaining
    result = :gen_udp.send(socket, host, port, data)

    {packet_size, result}
  end

  defp calculate_byte_size(data) do
    IO.iodata_length(data) + 1
  end
end
