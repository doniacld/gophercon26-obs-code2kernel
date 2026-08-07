#!/usr/bin/env bash
# Demo 3, part 2 — the mutex profile, then the execution trace.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-03-lock-contention"
source ../scripts/live-lib.sh
source ../scripts/demo3-common.sh

clear
banner "Demo 3 — part 2: a different question" \
	"the same process, under the same load"

step "Ask the mutex profile where contention accumulated"
liverun "$MUTEX" 'contention delay|Mutex.Unlock|computeUnderLock'

step "Capture an execution trace under load"
liverun "make trace" 'trace.out'

step "Blocking time, attributed to the call that blocked"
liverun "$SYNC" 'Mutex.Lock|acquire|computeUnderLock'

step "Scheduler latency: time runnable but not running"
liverun "$SCHED" 'nodes accounting for'

step "Open the timeline: one busy PROC row, the rest empty"
printf '%s$ %smake view\n' "$GREY" "$NC"
make view >/dev/null 2>&1 &
for _ in $(seq 40); do
	curl -s -o /dev/null --max-time 1 http://localhost:9091 && break
	sleep 0.5
done
showlink "http://localhost:9091"

printf '\n%sThe mutex profile says which lock. The trace says what the others were waiting for.%s\n' "$BOLD" "$NC"
