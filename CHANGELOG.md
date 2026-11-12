# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The `:peep_export_conversion_factor` reporter option. The values of a sum, a
  last_value or a distribution are multiplied by it when they are exported to
  Prometheus or StatsD. For a distribution, those are its sum and the bounds of
  its buckets.
- An optional `Peep.Storage.register_metrics/2` callback, called when Peep
  starts, which passes a storage backend Peep's metrics and the buckets of each
  distribution.
- A required `Peep.Buckets.boundaries/1` callback, which returns the boundaries
  between a calculator's buckets. Modules that `use Peep.Buckets.Custom` get it
  for free.
- This changelog.

### Changed

- **Breaking:** `Peep.Buckets.upper_bound/2` returns a float instead of a
  string. Modules that `use Peep.Buckets.Custom` need no change.
- **Breaking:** The bucket bounds of `Peep.Buckets.Exponential`, the default
  bucket calculator, are exported to Prometheus and StatsD without rounding.
  They were rounded to 6 decimal places: `le="1.222222"` is now
  `le="1.2222222222222223"`.
- **Breaking:** The buckets of a distribution in the result of
  `Peep.get_all_metrics/1` are keyed by float instead of by string.
  Implementations of `Peep.Storage` must return them the same way.
- `Peep.Storage.ETS` and `Peep.Storage.Striped` raise an `ArgumentError` that
  names the storage and the metric when a float is added to a sum. Both used
  to fail with a bare `badarg`.

### Fixed

- Identical metrics passed to Peep are deduplicated.
- StatsD lines for a metric without tags no longer end with an empty tag
  section (`|#`).
- A StatsD flush with nothing to report no longer sends an empty packet.
- `Peep.Plug` no longer logs an error when it responds 503 for a worker that
  isn't running.

## [5.1.0] - 2026-11-11

### Added

- An optional `Peep.Storage.insert_metrics/3` callback. A storage backend may
  export it instead of `insert_metric/5`, and is then passed every sample of a
  telemetry event in one call.

### Changed

- Peep requires Elixir 1.17 or later.
- `Peep.Storage.Striped` creates one table per scheduler instead of one per
  online scheduler, and no longer enables `write_concurrency` on them.
- Faster tagging of metrics with one or two tag keys, and faster inserts into
  distributions.

### Fixed

- A 2-arity `:keep` or `:drop` function is passed the event's measurements
  instead of `nil`.

## [5.0.1] - 2026-04-12

### Fixed

- Peep 5.0.0 failed to start when given `:statsd` options ([@yordis]).

## [5.0.0] - 2026-04-01

### Changed

- **Breaking:** Peep requires `:telemetry` 1.4 or later.
- **Breaking:** `Peep.Storage` has a new required callback, `resolve/1`.
- **Breaking:** `Peep.Persistent.ids_to_metrics/1` returns a tuple instead of a
  map.
- Faster handling of telemetry events.

### Removed

- **Breaking:** `Peep.insert_metric/4`, `Peep.assign_metric_ids/1` and
  `Peep.Persistent.fast_fetch/1`.

### Fixed

- StatsD no longer sends a line with the value `infinity` for distribution
  samples above `:max_value`.
- Peep erases its `:persistent_term` entry when it stops.
- Incorrect type specs.

## [4.4.0] - 2026-03-03

### Changed

- Telemetry events are handled by functions in `Peep.EventHandler` instead of
  by a module compiled when Peep starts ([@hauleth]).
- `Peep.Persistent` is a record instead of a struct ([@hauleth]).
- The default storage's ETS table uses `write_concurrency: :auto` ([@v0idpwn]).

### Removed

- `Peep.get_metric/3` and the `Peep.Storage.get_metric/4` callback.

## [4.3.1] - 2026-01-28

### Fixed

- Peep 4.3.0 failed to compile as a dependency
  ([#59](https://github.com/rkallos/peep/issues/59)).

## [4.3.0] - 2026-01-23

### Added

- Users can provide their own implementations of `Peep.Storage`, and test them
  against the test suite Peep uses internally ([@edgurgel]).

## [4.2.1] - 2025-11-27

### Fixed

- An incorrect type spec ([@v0idpwn]).

## [4.2.0] - 2025-08-25

### Fixed

- Peep's Prometheus export crashed while trying to convert terms to strings
  that don't implement the `String.Chars` protocol ([@pepicrft]).

## [4.1.1] - 2025-08-13

### Added

- Support for 2-ary callbacks for the `:keep` option in `Telemetry.Metrics`
  ([@hauleth]).

## [4.1.0] - 2025-08-12

### Added

- Peep emits a `:telemetry` event when reading storage size ([@hauleth]).
- Variables and the results of function calls can be passed in the list of
  buckets given to `use Peep.Buckets.Custom` ([@hauleth]).

### Changed

- Peep's Prometheus export text conforms to OpenMetrics ([@hauleth]).
- `Peep.Storage.Striped` uses a tuple instead of a map to access its ETS
  tables ([@hauleth]).
- Performance improvements to `Peep.Codegen`, removing some runtime
  indirection overhead ([@hauleth]).
- The threshold length that `Peep.Buckets.Custom` uses to decide between
  linear search and binary search was fine-tuned ([@hauleth]).

### Fixed

- Incorrect escaping in Peep's Prometheus export ([@hauleth]).

## [4.0.0] - 2025-05-12

### Added

- `Peep.Codegen`, an internal module that compiles a module on Peep startup
  with a `handle_event/4` function that replaces
  `Peep.EventHandler.handle_event/4`. This avoids the overhead of copying data
  out of `:telemetry`'s ETS table into a calling process's heap.

### Changed

- **Breaking:** Peep drops non-number measurements for last-value metrics
  (reported by [@akoutmos]).
- Peep automatically adds global tags to metrics, rather than forcing users to
  repeatedly specify the global tag keys in `:tags` for every metric (reported
  by [@yordis]).
- Peep gives integer ids to each metric, and uses those integer ids instead of
  `Telemetry.Metrics` structs when looking up data in ETS tables.

## [3.5.0] - 2025-02-28

### Added

- `Peep.prune_tags/2`, which deletes metrics based on matching tag values.

## [3.4.2] - 2025-01-31

### Fixed

- A bug around quote-escaping labels in Peep's Prometheus export ([@hauleth]).

## [3.4.1] - 2025-01-03

### Changed

- Peep requires Elixir 1.15 or later.

### Fixed

- Plug was required at compile-time. It is now truly an optional dependency
  ([@scudelletti]).

## [3.4.0] - 2024-12-30

### Added

- A compile-time `:bucket_calculator` option, making it possible to globally
  specify a `Peep.Buckets` implementation for all distribution metrics
  ([@yordis]).

### Changed

- Several optimizations to the Prometheus export code ([@josevalim]).
- `Peep.Buckets.Custom` switches from linear function head matching to binary
  search for large numbers of buckets, among other optimizations ([@hissssst]).

## [3.3.1] - 2024-11-26

### Added

- The `:on_unmatched_path` option for `Peep.Plug`, which decides the behaviour
  when `Peep.Plug` is called with an unexpected path: `:continue` when serving
  Peep metrics from the same HTTP server as your application, and `:halt` when
  serving them from a separate listener.

### Fixed

- The Bandit example in the documentation ([@yordis]).

## [3.3.0] - 2024-10-31

### Added

- The `:striped` storage, which trades increased memory usage for reduced lock
  contention. Rather than storing all metrics in a single ETS table, it uses
  one ETS table for each scheduler thread.
- `Peep.storage_size/1`.

## [3.2.1] - 2024-10-30

### Fixed

- Peep processes ignore unexpected messages instead of terminating ([@mjm]).
- Peep detaches its event handlers whatever the reason it terminates ([@mjm]).

## [3.2.0] - 2024-08-08

### Added

- `Peep.Plug`, an easy way to expose Peep metrics ([@aloukissas]).

## [3.1.0] - 2024-07-29

### Added

- The `:prometheus_type` reporter option, which overrides the type of a sum or
  last value metric in the Prometheus exposition ([@hauleth]).

## [3.0.0] - 2024-07-11

### Added

- The Apache 2.0 licence text.

### Changed

- **Breaking:** The `:global_tags` option is a map instead of a keyword list.
- Metric tags are stored in maps ([@hauleth]).
- `Peep.Buckets.Exponential` precomputes `:math.log(gamma)` for a slight
  performance boost.

## [2.1.3] - 2024-04-11

### Fixed

- The Prometheus export of `true`, `false` and `nil` values, and of `nil`
  label values.

## [2.1.2] - 2024-01-19

### Changed

- The requirements on `:nimble_options` and `:telemetry_metrics` are loosened
  to `>= 1.0.0` and `>= 0.6.0`.

## [2.1.1] - 2024-01-18

### Fixed

- Peep detaches its event handlers on shutdown ([@contested-space]).

## [2.1.0] - 2023-11-22

### Changed

- Counters and sums are stored once per scheduler, to reduce contention.

## [2.0.1] - 2023-10-31

### Fixed

- Distributions without a `:max_value` reporter option were dropped
  ([@contested-space]).

## [2.0.0] - 2023-10-16

### Added

- Support for custom bucket boundaries. The default log-linear bucketing
  strategy becomes `Peep.Buckets.Exponential`, an implementation of the new
  `Peep.Buckets` behaviour, and `Peep.Buckets.Custom` defines bucket boundaries
  of your own.

### Removed

- **Breaking:** The `distribution_bucket_variability` option.

### Fixed

- An issue with Prometheus exposition where zero-valued bucket time series are
  not shown.
- `Peep.Buckets.Exponential` puts values below 1, including negative values,
  in its first bucket.

## [1.0.1] - 2023-09-11

### Changed

- Peep's ETS table is created with `write_concurrency` and
  `decentralized_counters`.

### Fixed

- A deprecation warning for `Logger.warn/1`.

## [1.0.0] - 2023-05-02

### Added

- Initial release.

[unreleased]: https://github.com/rkallos/peep/compare/v5.1.0...HEAD
[5.1.0]: https://github.com/rkallos/peep/compare/v5.0.1...v5.1.0
[5.0.1]: https://github.com/rkallos/peep/compare/v5.0.0...v5.0.1
[5.0.0]: https://github.com/rkallos/peep/compare/v4.4.0...v5.0.0
[4.4.0]: https://github.com/rkallos/peep/compare/v4.3.1...v4.4.0
[4.3.1]: https://github.com/rkallos/peep/compare/v4.3.0...v4.3.1
[4.3.0]: https://github.com/rkallos/peep/compare/v4.2.1...v4.3.0
[4.2.1]: https://github.com/rkallos/peep/compare/v4.2.0...v4.2.1
[4.2.0]: https://github.com/rkallos/peep/compare/v4.1.1...v4.2.0
[4.1.1]: https://github.com/rkallos/peep/compare/v4.1.0...v4.1.1
[4.1.0]: https://github.com/rkallos/peep/compare/v4.0.0...v4.1.0
[4.0.0]: https://github.com/rkallos/peep/compare/v3.5.0...v4.0.0
[3.5.0]: https://github.com/rkallos/peep/compare/v3.4.2...v3.5.0
[3.4.2]: https://github.com/rkallos/peep/compare/v3.4.1...v3.4.2
[3.4.1]: https://github.com/rkallos/peep/compare/v3.4.0...v3.4.1
[3.4.0]: https://github.com/rkallos/peep/compare/v3.3.1...v3.4.0
[3.3.1]: https://github.com/rkallos/peep/compare/v3.3.0...v3.3.1
[3.3.0]: https://github.com/rkallos/peep/compare/v3.2.1...v3.3.0
[3.2.1]: https://github.com/rkallos/peep/compare/v3.2.0...v3.2.1
[3.2.0]: https://github.com/rkallos/peep/compare/v3.1.0...v3.2.0
[3.1.0]: https://github.com/rkallos/peep/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/rkallos/peep/compare/v2.1.3...v3.0.0
[2.1.3]: https://github.com/rkallos/peep/compare/v2.1.2...v2.1.3
[2.1.2]: https://github.com/rkallos/peep/compare/v2.1.1...v2.1.2
[2.1.1]: https://github.com/rkallos/peep/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/rkallos/peep/compare/v2.0.1...v2.1.0
[2.0.1]: https://github.com/rkallos/peep/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/rkallos/peep/compare/v1.0.1...v2.0.0
[1.0.1]: https://github.com/rkallos/peep/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/rkallos/peep/releases/tag/v1.0.0
[@aloukissas]: https://github.com/aloukissas
[@akoutmos]: https://github.com/akoutmos
[@contested-space]: https://github.com/contested-space
[@edgurgel]: https://github.com/edgurgel
[@hauleth]: https://github.com/hauleth
[@hissssst]: https://github.com/hissssst
[@josevalim]: https://github.com/josevalim
[@mjm]: https://github.com/mjm
[@pepicrft]: https://github.com/pepicrft
[@scudelletti]: https://github.com/scudelletti
[@v0idpwn]: https://github.com/v0idpwn
[@yordis]: https://github.com/yordis
