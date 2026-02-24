defmodule TelemetryTest do
  use ExUnit.Case, async: true

  alias Peep.Telemetry

  test "sent_packet emits [:peep, :packet, :sent] on success" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:peep, :packet, :sent]])
    Telemetry.sent_packet(42, :ok)
    assert_received {[:peep, :packet, :sent], ^ref, %{size: 42}, %{}}
  end

  test "sent_packet emits [:peep, :packet, :error] on error" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:peep, :packet, :error]])
    Telemetry.sent_packet(42, {:error, :econnrefused})
    assert_received {[:peep, :packet, :error], ^ref, %{}, %{reason: :econnrefused}}
  end
end
