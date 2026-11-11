defmodule Peep.Telemetry.Event do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      import Peep.Telemetry.Event
      Module.register_attribute(__MODULE__, :event_docs, accumulate: true)
    end
  end

  defmacro event_docs do
    quote do
      @event_docs |> Enum.reverse() |> Enum.join("\n\n")
    end
  end

  defmacro defevent(head, do: {:__block__, _, exprs}) do
    %{event: event, emitted: emitted, measurements: measurements, metadata: metadata} =
      Map.new(exprs, fn {key, _, [value]} -> {key, value} end)

    keys = fn
      {_var, keys} -> keys
      keys -> keys
    end

    expr = fn
      {var, _keys} -> var
      keys -> {:%{}, [], Enum.map(keys, fn {key, _doc} -> {key, Macro.var(key, nil)} end)}
    end

    fields = fn
      _title, [] ->
        ""

      title, keys ->
        "\n\n  #{title}:\n\n" <>
          Enum.map_join(keys, "\n", fn {key, doc} -> "  * `#{inspect(key)}` - #{doc}" end)
    end

    doc =
      "* `#{inspect(event)}`, emitted #{emitted}" <>
        fields.("Measurements", keys.(measurements)) <> fields.("Metadata", keys.(metadata))

    quote do
      @event_docs unquote(doc)
      @doc false
      def unquote(head) do
        :telemetry.execute(
          unquote(event),
          unquote(expr.(measurements)),
          unquote(expr.(metadata))
        )
      end
    end
  end
end

defmodule Peep.Telemetry do
  use Peep.Telemetry.Event

  defevent sent_packet(size, :ok) do
    event([:peep, :packet, :sent])
    emitted("after a StatsD packet is sent.")
    measurements(size: "the size of the packet, in bytes")
    metadata([])
  end

  defevent sent_packet(_size, {:error, reason}) do
    event([:peep, :packet, :error])
    emitted("when sending a StatsD packet fails.")
    measurements([])
    metadata(reason: "the error returned by the socket")
  end

  defevent storage_size(measurements, name, mod) do
    event([:peep, :storage])
    emitted("when `Peep.storage_size/1` is called.")

    measurements(
      {measurements,
       size: "the number of entries in the storage",
       memory: "the memory used by the storage, in bytes"}
    )

    metadata(name: "the name of the Peep reporter", mod: "the `Peep.Storage` implementation")
  end

  @moduledoc """
  `:telemetry` events for `Peep` itself.

  ## Telemetry events

  #{event_docs()}
  """
end
