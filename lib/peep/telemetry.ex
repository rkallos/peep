defmodule Peep.Telemetry do
  @moduledoc """
  `:telemetry` events for `Peep` itself.

  ## Telemetry events

  - `[:peep, :packet, :sent]`. Metadata contains `%{size: packet_size}`
  - `[:peep, :packet, :error]`. Metadata contains `%{reason: reason}`
  """

  def sent_packet(size, :ok) do
    measurements = %{size: size}
    metadata = %{}
    :telemetry.execute([:peep, :packet, :sent], measurements, metadata)
  end

  def sent_packet(_, {:error, reason}) do
    measurements = %{}
    metadata = %{reason: reason}
    :telemetry.execute([:peep, :packet, :error], measurements, metadata)
  end

  def storage_size(sizes, name, mod) do
    measurements = sizes
    metadata = %{name: name, mod: mod}
    :telemetry.execute([:peep, :storage], measurements, metadata)
  end
end
