#!/usr/bin/env bash
# The same request, on repeat, for the length of a capture window.
#
#   ./scripts/load.sh [SECONDS]        default 10
#
# Both captures in act 2 need the request to be running while they trace: a CPU
# profile of an idle process is empty, and off-CPU stacks of an idle process are
# the runtime's own idle loop. One request does not reliably outlast a 10 s window
# under the baseline quota, so it is reissued until the window closes.
#
# It is the identical request every time — same endpoint, same body, same job
# count — so the two profiles describe the same work, and the digest in the reply
# is there to prove it.
#
# Backgrounded on stage (`./scripts/load.sh 12 &`), which is why it prints nothing:
# a loop writing to the terminal underneath the profile output would be noise over
# the evidence. It stops on its own when the deadline passes.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SECS="${1:-10}"
APP_PORT="${APP_PORT:-8083}"
JOBS="${JOBS:-16}"

# +2 so the load outlives the capture rather than ending just inside it: a profile
# whose last second is idle reports a lower total than the window it claims.
deadline=$(( $(date +%s) + SECS + 2 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  curl -sS -X POST "http://localhost:$APP_PORT/compute" \
    -H 'Content-Type: application/json' \
    -d "{\"jobs\":$JOBS}" \
    --max-time 180 >/dev/null 2>&1 || true
done
