#!/usr/bin/env bash
# Print seconds of mutex waiting accumulated per second, read from the service's
# own /metrics.
#
# Usage: ./scripts/waitrate.sh [diag-port]
#
# The terminal twin of rate(demo3_mutex_wait_seconds_total[30s]): two reads of a
# counter, differenced over the wall-clock second between them. Because the
# counter is summed across goroutines it climbs faster than the clock — a result of
# 120 means roughly 120 goroutines spent that whole second waiting.
set -euo pipefail

port="${1:-6062}"
url="http://localhost:${port}/metrics"

# A failed scrape prints nothing rather than failing the script: this may run
# beside a service that is restarting, and "n/a" for one line beats an aborted
# demo.
read_wait() {
  curl -sf "$url" 2>/dev/null | awk '/^demo3_mutex_wait_seconds_total/ {print $2; exit}' || true
}

first=$(read_wait)
sleep 1
second=$(read_wait)

if [ -z "$first" ] || [ -z "$second" ]; then
  echo "n/a"
  exit 0
fi

awk -v a="$first" -v b="$second" 'BEGIN { printf "%.1f seconds of waiting per second\n", (b - a) }'
