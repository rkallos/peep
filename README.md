# Peep

![Hex version badge](https://img.shields.io/hexpm/v/peep)
![Hexdocs badge](https://img.shields.io/static/v1?message=hexdocs&label=&color=B1A5EE)
![Elixir CI badge](https://github.com/rkallos/peep/actions/workflows/elixir.yml/badge.svg)
![Hex licence badge](https://img.shields.io/hexpm/l/peep)

`Telemetry.Metrics` reporter for Prometheus and StatsD (including Datadog).

Peep has some important differences from libraries like
`TelemetryMetricsPrometheus.Core` and `TelemetryMetricsStatsd`:

- Instead of sampling or on-demand aggregation of samples, Peep estimates
  distributions using histograms.
- Instead of sending one datagram per telemetry event, Peep's StatsD reporting
  runs periodically, batching all lines into the smallest number of datagram
  packets possible while still obeying the configured `:mtu` setting.

To use it, start a reporter with `start_link/1`, providing a keyword list of
options (see `Peep.Options` for the schema against which options are validated).

```elixir
import Telemetry.Metrics

Peep.start_link(
  name: MyPeep,
  metrics: [
    counter("http.request.count"),
    sum("http.request.payload_size"),
    last_value("vm.memory.total")
  ]
)
```

or put it under a supervisor:

```elixir
import Telemetry.Metrics

children = [
  {Peep, [
    name: MyPeep,
    metrics: [
      counter("http.request.count"),
      sum("http.request.payload_size"),
      last_value("vm.memory.total")
    ]
  ]}
]

Supervisor.start_link(children, ...)
```

By default, Peep does not emit StatsD data. It can be enabled by passing in
configuration with the `statsd` keyword. Peep's StatsD reporting supports Unix
Domain Sockets.

## What's Missing

Currently, there's no implementation of 'summary' metrics. Since histograms are
relatively inexpensive in Peep, we suggest you use 'distribution' metrics
instead.

## Installation

Peep package can be installed by adding `peep` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:peep, "~> 3.3"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/peep>.
