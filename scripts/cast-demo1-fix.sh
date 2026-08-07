#!/usr/bin/env bash
# Demo 1, part 2 — the change, one request, the trace.
#
# Runs after cast-demo1-load.sh, once the audience has read the waterfall and
# said what it shows. The diff is the payoff, so it appears here and nowhere
# earlier. No load and no timing summary: the comparison happens in Jaeger,
# between two waterfalls, not between two numbers in a terminal.
#
# Prerequisites, both outside the cast so the recording stays short:
#   make up                                    (Jaeger, at the repository root)
#   make -C demo-01-otel-sequential-calls after
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-01-otel-sequential-calls"
source ../scripts/cast-lib.sh

JAEGER=${JAEGER_URL:-http://localhost:16686}
TAGS='%7B%22demo.mode%22%3A%22fixed%22%7D'
SEARCH="$JAEGER/search?service=frontend&tags=$TAGS&sortBy=LONGEST_FIRST&limit=20&lookback=1h"

clear
banner "Demo 1 — the change" \
	"internal/dashboard/dashboard.go — the same three calls, issued differently"

note "The fix: fetch the three dependencies concurrently"
codediff internal/dashboard/dashboard.go Sequential Concurrent

note "Sending one request on /dashboard"
run "curl -sv -o /dev/null http://localhost:8080/dashboard" '< HTTP'

note "Open the trace in Jaeger"
link "$SEARCH"

closing "Put this waterfall next to the first one."
