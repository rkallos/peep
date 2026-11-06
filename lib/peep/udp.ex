defmodule Peep.UDP do
  @moduledoc false

  @udp Application.compile_env(:peep, :udp_module, :gen_udp)

  defdelegate open(port, opts), to: @udp
  defdelegate send(socket, host, port, data), to: @udp
end
