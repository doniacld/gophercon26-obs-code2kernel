#!/usr/bin/env bash
# Demo 2, act 3 — the fix, the same load, the same profile.
#
# Runs after act 2, once the room has read the [chan send] stack and named the
# line. The diff is the payoff, so it comes first; then the identical hundred
# requests, and the identical two commands, so the comparison is between two
# outputs of the same question rather than between two different questions.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-02-goroutine-leak"
source ../scripts/cast-lib.sh
source ../scripts/demo2-common.sh

clear
banner "Demo 2 — act 3: the fix" \
	"server.go — the handler pprof pointed at"

note "The fix: the request's context, and a guarded send"
codediff server.go handleWorkBroken handleWorkFixed

note "Restart the service"
run "./scripts/serve.sh --fixed" 'ready:'

note "Sending traffic on /work"
run "$LOAD"

note "Get number of goroutines metric"
run "$GAUGE" '^go_goroutines '

note "List every goroutine and its state"
run "$PROFILE_LIST" 'chan send'

note "Count goroutines parked on a channel send"
run "$BLOCKED" '^0$'
