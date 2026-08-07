#!/usr/bin/env bash
# Demo 4, act 2 — the CPU profile.
#
#   ./scripts/live-demo4-2-pprof.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-04-cpu-quota"
source ../scripts/live-lib.sh
# shellcheck source=demo4-common.sh
source ../scripts/demo4-common.sh

assert_quota

# The profile needs the request in flight: a CPU profile of an idle process is empty.
step "Put the request on repeat, in the background"
liverun "$LOAD"

# Sampled from the running process over 10 s.
step "Sample a CPU profile"
liverun "$PROFILE"
profile_job=$!
wait "$profile_job" 2>/dev/null || true

# Duration is the window; Total samples is the CPU time inside it.
step "What the profile caught"
liverun "$CPU_TOP"
