defmodule Peep.UDP do
  @moduledoc false

  @udp if Mix.env() == :test, do: Peep.Test.UDP, else: :gen_udp

  defdelegate open(port, opts), to: @udp
  defdelegate send(socket, host, port, data), to: @udp
end
