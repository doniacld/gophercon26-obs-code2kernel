#!/usr/bin/env bash
# Demo 3, part 3 — the fix, the same load, the same commands.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-03-lock-contention"
source ../scripts/live-lib.sh
source ../scripts/demo3-common.sh

clear
banner "Demo 3 — part 3: Implement the fix" \
	"internal/work/work.go — the critical section the mutex profile named"

step "The fix: compute first, lock only to store"
codediff internal/work/work.go computeUnderLock computeThenStore

step "Stop the load, restart with the mutex covering storeResult only"
liverun "make workload-stop unlocked" 'demo 3 ready'

step "One request: the same 16 tasks, the same 100ms each"
liverun "$ONE" '"wall_ms"|"peak_working"|"speedup"'

step "Start the same sustained load"
liverun "make load-start" 'load running'

step "Scrape the metrics again"
liverun "$SCRAPE" '^demo3_active_workers|^go_sched_gomaxprocs_threads'

step "Cores the process actually consumes"
liverun "$CORES" 'cores'

step "Mutex wait accumulated per second"
liverun "$WAIT_RATE" 'seconds of waiting'

step "Ask the mutex profile again"
liverun "$MUTEX" 'contention delay|Total samples'

printf '\n%sConcurrency does not guarantee parallelism.%s\n' "$BOLD" "$NC"
printf '%sSame code, same answers — only the lock moved.%s\n' "$GREY" "$NC"
printf '%smake -C demo-03-lock-contention workload-stop down%s\n' "$GREY" "$NC"
