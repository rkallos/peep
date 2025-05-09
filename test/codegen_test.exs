defmodule Codegen.Test do
  use ExUnit.Case

  alias Peep.Support.StorageCounter
  alias Telemetry.Metrics

  defp metrics do
    counter = Metrics.counter("peep.counter", event_name: [:counter])
    sum = Metrics.sum("peep.sum", event_name: [:sum], measurement: :count)

    last_value =
      Metrics.last_value("peep.gauge", event_name: [:gauge], measurement: :value)

    distribution =
      Metrics.distribution("peep.dist",
        event_name: [:dist],
        measurement: :value,
        reporter_options: [max_value: 100]
      )

    [counter, sum, last_value, distribution]
  end

  test "module exists after Peep starts" do
    name = StorageCounter.fresh_id()

    options = [
      name: name,
      metrics: metrics()
    ]

    assert {:ok, _pid} = Peep.start_link(options)
    module = Peep.Codegen.module(name)

    for {%{event_name: event_name} = metric, id} <- metrics() do
      assert module.metrics(event_name) == [{metric, id}]
    end
  end
end
