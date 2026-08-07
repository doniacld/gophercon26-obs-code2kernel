#!/usr/bin/env bash
# Demo 1, part 2, live — the change, one request, the new trace in Jaeger.
#
# The live twin of scripts/cast-demo1-fix.sh. Run after live-demo1-1-load.sh, once
# the audience has read the first waterfall and said what it shows.
#
# The diff comes first because it is the payoff. No load and no timing summary:
# the comparison belongs in Jaeger, between two waterfalls, not between two
# numbers in a terminal.
#
#   ./scripts/live-demo1-2-fix.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-01-otel-sequential-calls"
source ../scripts/live-lib.sh

JAEGER=${JAEGER_URL:-http://localhost:16686}
TAGS='%7B%22demo.mode%22%3A%22fixed%22%7D'
SEARCH="$JAEGER/search?service=frontend&tags=$TAGS&sortBy=LONGEST_FIRST&limit=20&lookback=1h"

clear
banner "Demo 1 — the change" \
	"internal/dashboard/dashboard.go — the same three calls, issued differently"

step "The fix: fetch the three dependencies concurrently"
codediff internal/dashboard/dashboard.go Sequential Concurrent

# Restarting on the corrected path is a step of its own rather than part of
# prepare: live, the audience has just read the diff and should see the code they
# read go into effect, instead of it having happened silently before the script
# started.
step "Restart the frontend"
liverun "make after 2>&1 | grep -v 'at the same time'" 'demo 1 ready'

step "Sending one request on /dashboard"
liverun "curl -sv -o /dev/null http://localhost:8080/dashboard" '< HTTP'

step "The trace in Jaeger"
showlink "$SEARCH"

printf '\n%sPut this waterfall next to the first one.%s\n' "$BOLD" "$NC"
printf '%sWhen you are done: make -C demo-01-otel-sequential-calls down%s\n' "$GREY" "$NC"
