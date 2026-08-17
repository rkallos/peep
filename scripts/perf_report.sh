#!/usr/bin/env bash
# Renders a compact flat profile from a perf.data recorded by run_perf.sh.
# perf pads the symbol column to a fixed enormous width, so squeeze it.
#
#   ./scripts/perf_report.sh <backend> [percent_limit] [rows]
set -euo pipefail

BACKEND="${1:?usage: perf_report.sh <backend> [percent_limit] [rows]}"
LIMIT="${2:-0.4}"
ROWS="${3:-35}"

perf report -i "/tmp/prof-${BACKEND}.data" --stdio --no-children -g none \
  --sort symbol --percent-limit "$LIMIT" 2>/dev/null |
  grep -E '^\s+[0-9]+\.[0-9]+%' |
  sed -E 's/^[[:space:]]+//; s/\[\.\] //; s/[[:space:]]+-[[:space:]]+-[[:space:]]*$//' |
  sed -E "s/\\\$'Elixir\.([^']*)'/\1/; s/\\\$Elixir\.//" |
  sed -E 's/[[:space:]]+$//' |
  head -"$ROWS"
