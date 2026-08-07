#!/usr/bin/env bash
# Demo 2, act 3, live — the fix, the same load, the same profile.
#
# The live twin of scripts/cast-demo2-fix.sh. Run last, after the room has read the
# [chan send] stack and named the line themselves.
#
# The same two profile commands as act 2, deliberately: the comparison should be
# between two answers to one question, not between two questions.
#
#   ./scripts/live-demo2-3-fix.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-02-goroutine-leak"
source ../scripts/live-lib.sh
source ../scripts/demo2-common.sh

clear
banner "Demo 2 — act 3: the fix" \
	"server.go — the handler pprof pointed at"

step "The fix: the request's context, and a guarded send"
codediff server.go handleWorkBroken handleWorkFixed

step "Restart the service"
liverun "./scripts/serve.sh --fixed" 'ready:'

step "Sending traffic on /work"
liverun "$LOAD"

step "Get number of goroutines metric"
liverun "$GAUGE" '^go_goroutines '

step "List every goroutine and its state"
liverun "$PROFILE_LIST" 'chan send'

step "Count goroutines parked on a channel send"
liverun "$BLOCKED" '^0$'

printf '%sWhen you are done: make -C demo-02-goroutine-leak down%s\n' "$GREY" "$NC"
