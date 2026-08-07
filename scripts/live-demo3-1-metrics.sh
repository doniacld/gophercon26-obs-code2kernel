#!/usr/bin/env bash
# Demo 3, part 1 — the metrics, and the CPU profile that agrees with them.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-03-lock-contention"
source ../scripts/live-lib.sh
source ../scripts/demo3-common.sh

clear
banner "Demo 3 — part 1: the metrics" \
	"a compute service on :8082, its /metrics and /debug/pprof on :6062"

# `make up` rather than `make locked`, and stage.sh's ready line has MODE stripped
# out of it, for the reason demo 1 filters "at the same time": part 1 has to be
# sayable about a process nobody has read the source of. A highlighted
# "ready in MODE=locked" hands the room the answer before the first metric is read.
step "Start the service"
liverun "make up 2>&1 | sed 's/ in MODE=[a-z]*//'" 'demo 3 ready'

step "One request: 16 independent tasks, 100ms of CPU each"
liverun "$ONE" '"wall_ms"|"peak_working"|"speedup"'

step "Start sustained load: 8 concurrent requests"
liverun "make load-start" 'load running'

step "Scrape the metrics: workers alive, cores available"
liverun "$SCRAPE" '^demo3_active_workers|^go_sched_gomaxprocs_threads'

step "Cores the process actually consumes"
liverun "$CORES" 'cores'

step "Mutex wait accumulated per second"
liverun "$WAIT_RATE" 'seconds of waiting'

step "Ask a CPU profile where the time goes"
liverun "$CPU" 'Duration|Total samples|fnv'

printf '\n%sMetrics tell us that the application is not using the available CPU capacity.%s\n' "$BOLD" "$NC"
printf '%sThe CPU profile says the same thing. Neither says why.%s\n' "$GREY" "$NC"
showlink "$METRICS"
