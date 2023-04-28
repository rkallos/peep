defmodule Peep do
  @moduledoc """
  `Telemetry.Metrics` reporter for:
  * StatsD-compatible metric servers
  * Prometheus

  To use it, start the reporter with `start_link/1`, providing a list of
  `Telemetry.Metrics` metric definitions:
  """
  use GenServer
  require Logger
  alias Peep.{EventHandler, Options, Storage, Statsd}

  defmodule State do
    defstruct tid: nil,
              interval: nil,
              handler_ids: nil,
              statsd_opts: nil,
              statsd_state: nil
  end

  def child_spec(options) do
    %{id: peep_name!(options), start: {__MODULE__, :start_link, [options]}}
  end

  def start_link(options) do
    case Options.validate(options) do
      {:ok, options} ->
        GenServer.start_link(__MODULE__, options, name: options.name)

      {:error, _} = err ->
        err
    end
  end

  def get_all_metrics(name_or_pid) do
    GenServer.call(name_or_pid, :get_all_metrics)
  end

  @impl true
  def init(options) do
    tid = Storage.new(options.name, options.distribution_bucket_variability)

    metrics = options.metrics
    handler_ids = EventHandler.attach(metrics, tid, options.global_tags)

    statsd_opts = options.statsd
    statsd_flush_interval = statsd_opts[:flush_interval_ms]

    if statsd_flush_interval != nil do
      set_statsd_timer(statsd_flush_interval)
    end

    statsd_state =
      if options.statsd do
        Statsd.make_state(statsd_opts)
      else
        nil
      end

    state = %State{
      tid: tid,
      handler_ids: handler_ids,
      statsd_opts: statsd_opts,
      statsd_state: statsd_state
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_all_metrics, _from, %State{tid: tid} = state) do
    {:reply, Storage.get_all_metrics(tid), state}
  end

  @impl true
  def handle_info(:statsd_flush, %State{statsd_state: nil} = state) do
    {:noreply, state}
  end

  def handle_info(
        :statsd_flush,
        %State{tid: tid, statsd_state: statsd_state, statsd_opts: statsd_opts} = state
      ) do
    new_statsd_state =
      Storage.get_all_metrics(tid)
      |> Statsd.make_and_send_packets(statsd_state)

    set_statsd_timer(statsd_opts[:flush_interval_ms])
    {:noreply, %State{state | statsd_state: new_statsd_state}}
  end

  defp set_statsd_timer(interval) do
    Process.send_after(self(), :statsd_flush, interval)
  end

  defp peep_name!(options) do
    Keyword.get(options, :name) || raise(ArgumentError, "a name must be provided")
  end
end
