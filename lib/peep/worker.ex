defmodule Peep.Worker do
  use GenServer

  alias Peep.EventHandler

  defmodule State do
    defstruct tid: nil, interval: nil, handler_ids: nil
  end

  def child_spec(options) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}
  end

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  def get_all_metrics() do
    GenServer.call(__MODULE__, :get_all_metrics)
  end

  @impl true
  def init(options) do
    tid = :ets.new(:ordered_set, [:public])

    metrics = Keyword.fetch!(options, :metrics)
    handler_ids = EventHandler.attach(metrics, tid)
    {:ok, %State{tid: tid, handler_ids: handler_ids}}
  end

  @impl true
  def handle_call(:get_all_metrics, _from, %State{tid: tid} = state) do
    {:reply, Storage.get_all(tid), state}
  end
end
