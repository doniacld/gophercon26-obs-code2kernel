#!/usr/bin/env bash
# Print the CPU cores the demo 3 process is currently consuming, read from its
# own /metrics.
#
# Usage: ./scripts/cores.sh [diag-port]
#
# This is the same arithmetic Prometheus does for
# rate(process_cpu_seconds_total[30s]) — two samples of a counter of CPU-seconds,
# divided by the wall time between them. It exists so the terminal can show the
# number while the graph is being set up, and so nothing on stage depends on a
# browser being ready.
set -euo pipefail

port="${1:-6062}"
url="http://localhost:${port}/metrics"

# A failed scrape prints nothing rather than failing the script: this runs inside
# a progress loop, and "n/a" for one line is better than killing the workload.
read_cpu() {
  curl -sf "$url" 2>/dev/null | awk '/^process_cpu_seconds_total/ {print $2; exit}' || true
}

first=$(read_cpu)
sleep 1
second=$(read_cpu)

if [ -z "$first" ] || [ -z "$second" ]; then
  echo "n/a"
  exit 0
fi

awk -v a="$first" -v b="$second" 'BEGIN { printf "%.2f cores\n", (b - a) }'
