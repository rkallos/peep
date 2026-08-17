#!/usr/bin/env bash
# Records a perf profile of one Peep storage backend under a steady
# :telemetry.execute load, then prints a flat symbol profile.
#
#   ./scripts/run_perf.sh <backend> [duration_ms]
#
# Methodology notes:
#   * `+JPperf true` makes the BEAM JIT emit /tmp/perf-<pid>.map so perf can
#     resolve Erlang/Elixir frames rather than showing bare JIT addresses.
#   * `+S N:N` sizes the scheduler pool to the worker count, so idle schedulers
#     don't fill the profile with scheduler_wait spinning.
#   * taskset pins to one hardware thread per P-core (0,2,4,6 on this i5-1240P);
#     mixing P and E cores splits perf's PMU events into cpu_core/cpu_atom and
#     fragments the report, and HT siblings would contend.
#   * `-e cpu-clock` is a software event, uniform across core types.
set -euo pipefail

BACKEND="${1:?usage: run_perf.sh <backend> [duration_ms]}"
DUR="${2:-10000}"
CPUS="${CPUS:-0,2,4,6}"
SCHED="${SCHED:-4}"
PROCS="${PROCS:-4}"
CALLGRAPH="${CALLGRAPH:-none}"

OUT="/tmp/prof-${BACKEND}.data"
rm -f "$OUT"

RECORD_ARGS=(-e cpu-clock -F 999 -o "$OUT")
if [ "$CALLGRAPH" != "none" ]; then
  RECORD_ARGS+=(--call-graph "$CALLGRAPH")
fi

ERL_FLAGS="+JPperf true +S ${SCHED}:${SCHED}" \
BACKEND="$BACKEND" PROCS="$PROCS" DURATION_MS="$DUR" MIX_ENV=dev \
  taskset -c "$CPUS" perf record "${RECORD_ARGS[@]}" -- mix run scripts/profile_workload.exs

echo
echo "=== flat profile: ${BACKEND} ==="
perf report -i "$OUT" --stdio --no-children -g none --sort symbol \
  --percent-limit "${LIMIT:-0.4}" 2>/dev/null | grep -v '^#' | grep -v '^$' | head -40
