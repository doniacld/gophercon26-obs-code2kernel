#!/usr/bin/env bash
# Demo 4, act 1 — one request, timed.
#
#   ./scripts/live-demo4-1-request.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-04-cpu-quota"
source ../scripts/live-lib.sh
# shellcheck source=demo4-common.sh
source ../scripts/demo4-common.sh

eval "$UP" >/dev/null 2>&1
assert_quota

# 16 independent jobs of SHA-256 arithmetic. No lock, no I/O, no sleep.
step "One request"
liverun "$ONE"
