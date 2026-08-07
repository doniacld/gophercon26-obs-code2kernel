#!/usr/bin/env bash
# Demo 3 screencast — the commands from demo-03-lock-contention/README.md, run
# for real, in the order its speaker flow gives them.
#
# `make view` is deliberately absent: it opens a browser and blocks. `make sync`
# is the README's terminal-only substitute for the same evidence.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-03-lock-contention"
source ../scripts/cast-lib.sh

clear
banner "Demo 3 — a compute service, and the time it takes" \
	"16 independent 100 ms tasks on 11 processors."

run "make locked" 'MODE=locked'

run "make one" '"peak_working"|"speedup"|"lock_wait_ms"|"parallelism"|"wall_ms"'
run "make load" 'wall=|p95=|peak concurrent tasks|lock wait'

run "make profile-mutex" 'Showing nodes accounting|Mutex.Unlock|computeUnderLock|contention delay'
note "The mutex profile"

run "make sync" 'Showing nodes accounting|Mutex.Lock|WaitGroup.Wait|acquire'
note "The sync profile from the execution trace"

run "make unlocked" 'MODE=unlocked'

run "make one" '"peak_working"|"speedup"|"lock_wait_ms"|"parallelism"|"wall_ms"'
run "make load" 'wall=|p95=|peak concurrent tasks|lock wait'

run "make profile-mutex" 'Showing nodes accounting|us total'

closing "A profile is a photograph of where time was spent. A trace is the film."
