#!/usr/bin/env bash
# Demo 2, act 2 — instrument with pprof, run the same traffic, read the profile.
#
# Act 1 left a number nobody can explain. This act adds one line of
# instrumentation, shows it as a diff, sends the identical requests, and asks the
# runtime what those goroutines are doing.
#
# The diff is extracted from server.go at run time, so both sides of it are code
# that really ran: -pprof=false in act 1 served diagnosticsMetrics, and the restart
# here serves diagnosticsProfiling.
#
# Narration is command titles only. "One stack, repeated" is pprof's line and it
# lands harder printed than predicted, so nothing on screen reads the output back;
# the speaker does that, and says why the requests provoke it only once the stack
# has named the line — the order the room would discover it in.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-02-goroutine-leak"
source ../scripts/cast-lib.sh
source ../scripts/demo2-common.sh

clear
banner "Demo 2 — act 2: the profile" \
	"server.go — one more handler on the diagnostics listener"

note "Add pprof to the diagnostics endpoint"
codediff server.go diagnosticsMetrics diagnosticsProfiling

note "Restart the service"
run "./scripts/serve.sh" 'ready:'

note "Sending traffic on /work"
run "$LOAD"

note "Get number of goroutines metric"
run "$GAUGE" '^go_goroutines '

note "List every goroutine and its state"
run "$PROFILE_LIST" 'chan send'

note "One of those stacks, in full"
run "$PROFILE_STACK" 'chan send'

closing "The metric tells us what is growing. The profile tells us where it is stuck."
