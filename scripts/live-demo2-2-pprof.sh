#!/usr/bin/env bash
# Demo 2, act 2, live — instrument with pprof, the same traffic, read the profile.
#
# The live twin of scripts/cast-demo2-pprof.sh. Run after live-demo2-1-metric.sh,
# once the room has watched the gauge climb and stay there.
#
# The diff comes first: it is what the previous act was missing. Both sides of it
# are extracted from server.go at run time, so the code on screen is the code that
# ran a moment ago and the code about to run.
#
# Narration is command titles only. "One stack, repeated" is pprof's line and it
# lands harder printed than predicted, so nothing on screen reads the output back;
# the speaker does that, and says why the requests provoke it only once the stack
# has named the line — the order the room would discover it in.
#
#   ./scripts/live-demo2-2-pprof.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-02-goroutine-leak"
source ../scripts/live-lib.sh
source ../scripts/demo2-common.sh

clear
banner "Demo 2 — act 2: the profile" \
	"server.go — one more handler on the diagnostics listener"

step "Add pprof to the diagnostics endpoint"
codediff server.go diagnosticsMetrics diagnosticsProfiling

step "Restart the service"
liverun "./scripts/serve.sh" 'ready:'

step "Sending traffic on /work"
liverun "$LOAD"

step "Get number of goroutines metric"
liverun "$GAUGE" '^go_goroutines '

step "List every goroutine and its state"
liverun "$PROFILE_LIST" 'chan send'

step "One of those stacks, in full"
liverun "$PROFILE_STACK" 'chan send'

printf '\n%sThe metric tells us what is growing. The profile tells us where it is stuck.%s\n' "$BOLD" "$NC"
printf '%sAsk the room for the fix before running ./scripts/live-demo2-3-fix.sh.%s\n' "$GREY" "$NC"
