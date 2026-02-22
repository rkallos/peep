defmodule Peep.EventHandler do
  @moduledoc false

  @compile :inline

  def attach(name) do
    %Peep.Persistent{events_to_metrics: metrics_by_event} = Peep.Persistent.fetch(name)
    module = Peep.Codegen.module(name)

    for {event_name, _metrics} <- metrics_by_event do
      handler_id = handler_id(event_name, name)

      :ok =
        :telemetry.attach(
          handler_id,
          event_name,
          &module.handle_event/4,
          []
        )

      handler_id
    end
  end

  def detach(handler_ids) do
    for id <- handler_ids, do: :telemetry.detach(id)
    :ok
  end

  defp handler_id(event_name, peep_name) do
    {__MODULE__, peep_name, event_name}
  end
end
