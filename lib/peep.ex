defmodule Peep do
  @moduledoc """
  `Telemetry.Metrics` reporter supporting Statsd and Prometheus.

  To use it, start the reporter with `start_link/1`, providing a list of
  `Telemetry.Metrics` metric definitions in a Keyword list matching the schema
  specified in `Peep.Options`:

      import Telemetry.Metrics

      Peep.start_link([
        name: :my_peep,
        metrics: [
          counter("http.request.count"),
          sum("http.request.payload_size"),
          last_value("vm.memory.total"),
          distribution("http.request.latency")
        ]
      ])

  To emit Statsd metrics, `Peep` supports both UDP and Unix Domain Sockets.

  ## Why another `Telemetry.Metrics` library?

  Both `TelemetryMetricsStatsd` and `TelemetryMetrics.Prometheus` are great
  choices for emitting telemetry. However, `Peep` makes several different
  choices that may not be as general-purpose as either of those libraries.

  ### No sampled metrics

  Sampling is a popular approach to reduce the amount of Statsd data flowing out
  of a service, but naive sampling dramatically reduces visibility into the
  shapes of distributions. `Peep` represents distributions using histograms,
  using a small exponential function by default. This sacrifices some
  granularity on individual samples, but one usually doesn't mind too much if a
  sample value of `95` is rounded to `100`, or if `950` is rounded to `1000`.
  These histograms are emitted to statsd using the optional sample rate of
  `1/$count`.

  `Peep` uses `:atomics` stored in `:ets` for performance. New `:atomics` arrays
  are created when a metric with a new set of tags is observed, so there is a
  slight overhead when handling the first telemetry event with a distinct set of
  tags. `Peep` reporter processes are not involved in the handling of any
  `:telemetry` events, so there's no chance of a single process becoming a
  bottleneck.

  ### Distributions are aggregated immediately

  This is a consequence of choosing to represent distributions as
  histograms. There is no step in `Peep`'s processing where samples are
  aggregated in large batches. This leads to a flatter performance profile when
  scaling up.

  ### Statsd packets are stuffed

  This is something that is not (at the time of writing) supported by
  `TelemetryMetricsStatsd`, but the need for stuffing packets became pretty
  clear when handling tens of thousands of telemetry events every second. During
  each reporting period, metrics collected by a `Peep` reporter will be
  collected into a minimum number of packets. Users can set the maximum packet
  size in `Peep.Options`.

  ## Supported `:reporter_options`

  - `:prometheus_type` - when using `sum/2` or `last_value/2` you can use this
    option to define Prometheus' type used by such metric. By default `sum/2`
    uses `counter` and `last_value/2` uses `gauge`. It can be useful when some
    values are already precomputed, for example presummed socket stats.
  """
  use GenServer
  require Logger
  alias Peep.{EventHandler, Options, Statsd}

  defmodule State do
    @moduledoc false
    defstruct name: nil,
              interval: nil,
              handler_ids: nil,
              statsd_opts: nil,
              statsd_state: nil
  end

  @type metric_id() :: pos_integer()

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

  def insert_metric(name, metric, value, tags) when is_number(value) do
    case Peep.Persistent.fetch(name) do
      %Peep.Persistent{
        storage: {storage_mod, storage},
        metrics_to_ids: %{^metric => id}
      } ->
        storage_mod.insert_metric(storage, id, metric, value, tags)

      _ ->
        nil
    end
  end

  def insert_metric(_name, _metric, _value, _tags), do: nil

  @doc """
  Returns measurements about the size of a running Peep's storage, in number of
  ETS elements and in bytes of memory.
  """
  @spec storage_size(atom()) :: %{size: non_neg_integer(), memory: non_neg_integer()}
  def storage_size(name) do
    case Peep.Persistent.storage(name) do
      {storage_mod, storage} ->
        measurements = storage_mod.storage_size(storage)

        Peep.Telemetry.storage_size(measurements, name, storage_mod)

        measurements

      _ ->
        nil
    end
  end

  @doc """
  Fetches all metrics from the worker. Called when preparing Prometheus or
  StatsD data.
  """
  def get_all_metrics(name) do
    case Peep.Persistent.fetch(name) do
      %Peep.Persistent{storage: {storage_mod, storage}} = p ->
        storage_mod.get_all_metrics(storage, p)

      _ ->
        nil
    end
  end

  @doc """
  Fetches a single metric from storage. Currently only used in tests.
  """
  def get_metric(name, metric, tags) when is_list(tags) do
    get_metric(name, metric, Map.new(tags))
  end

  def get_metric(name, metric, tags) do
    case Peep.Persistent.fetch(name) do
      %Peep.Persistent{
        storage: {storage_mod, storage},
        metrics_to_ids: %{^metric => id}
      } ->
        storage_mod.get_metric(storage, id, metric, tags)

      _ ->
        nil
    end
  end

  @doc """
  Removes metrics whose metadata contains the specified tag patterns.

  Example inputs:

  - `[%{foo: :bar}, %{baz: :quux}]` removes metrics with `foo == :bar` OR `baz == :quux`
  - `[%{foo: :bar, baz: :quux}]` removes metrics with `foo == :bar` AND `baz == :quux`
  - `[%{foo: :one}, %{foo: :two}]` removes metrics with `foo == :one` OR `foo == :two`
  """
  def prune_tags(name, tags_patterns) do
    case Peep.Persistent.storage(name) do
      {storage_mod, storage} ->
        storage_mod.prune_tags(storage, tags_patterns)

      _ ->
        nil
    end
  end

  def allow_metric?(%Telemetry.Metrics.Summary{} = metric) do
    Logger.warning("The summary metric type is unsupported. Dropping #{inspect(metric.name)}")
    false
  end

  def allow_metric?(%Telemetry.Metrics.Distribution{reporter_options: opts} = metric) do
    key = :max_value

    case Keyword.get(opts, key) do
      nil ->
        true

      n when is_number(n) ->
        true

      _ ->
        Logger.warning(
          "Distributions must have a numeric value assigned to #{inspect(key)} in reporter_options. Dropping #{inspect(metric.name)}"
        )

        false
    end
  end

  def allow_metric?(_) do
    true
  end

  def assign_metric_ids(metrics) do
    filtered_metrics = Enum.filter(metrics, &allow_metric?/1)

    assign_metric_ids(
      Enum.reverse(filtered_metrics),
      %{},
      %{},
      %{},
      length(filtered_metrics)
    )
  end

  defp assign_metric_ids([], events_to_metrics, ids_to_metrics, metrics_to_ids, _counter) do
    %{
      events_to_metrics: events_to_metrics,
      ids_to_metrics: ids_to_metrics,
      metrics_to_ids: metrics_to_ids
    }
  end

  defp assign_metric_ids([metric | rest], etm, itm, mti, counter) do
    %{event_name: event_name} = metric

    etm =
      case etm do
        %{^event_name => metrics} ->
          %{etm | event_name => [{metric, counter} | metrics]}

        _ ->
          Map.put(etm, event_name, [{metric, counter}])
      end

    itm = Map.put(itm, counter, metric)
    mti = Map.put(mti, metric, counter)

    assign_metric_ids(rest, etm, itm, mti, counter - 1)
  end

  # callbacks

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    name = options.name

    :ok =
      Peep.Persistent.new(options)
      |> Peep.Persistent.store()

    :ok = Peep.Codegen.create(options)
    handler_ids = EventHandler.attach(name)

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
      name: name,
      handler_ids: handler_ids,
      statsd_opts: statsd_opts,
      statsd_state: statsd_state
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:statsd_flush, %State{statsd_state: nil} = state) do
    {:noreply, state}
  end

  def handle_info(
        :statsd_flush,
        %State{name: name, statsd_state: statsd_state, statsd_opts: statsd_opts} = state
      ) do
    new_statsd_state =
      Peep.get_all_metrics(name)
      |> Statsd.make_and_send_packets(statsd_state)

    set_statsd_timer(statsd_opts[:flush_interval_ms])
    {:noreply, %State{state | statsd_state: new_statsd_state}}
  end

  def handle_info(_msg, state) do
    # In particular, OTP can sometimes leak `:inet_reply` messages when a UDS datagram
    # socket blocks, and Peep should not terminate the server and lose state when that
    # happens.
    #
    # https://github.com/rkallos/peep/pull/17
    # https://github.com/erlang/otp/issues/8989
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{name: name, handler_ids: handler_ids}) do
    Peep.Codegen.purge(name)
    Peep.Persistent.erase(name)
    EventHandler.detach(handler_ids)
  end

  # private

  defp set_statsd_timer(interval) do
    Process.send_after(self(), :statsd_flush, interval)
  end

  defp peep_name!(options) do
    Keyword.get(options, :name) || raise(ArgumentError, "a name must be provided")
  end
end
