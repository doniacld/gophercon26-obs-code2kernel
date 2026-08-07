#!/usr/bin/env bash
# Stage driver for demo 3. Invoked by the Makefile; not meant to be run directly.
#
# Usage: MODE=locked|unlocked ./stage.sh {up|down|status}
#
# One process. Only -mode changes between the two halves of the demo: same
# goroutines, same work, same results, different lock placement.

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=../scripts/lib.sh
source ../scripts/lib.sh

MODE="${MODE:-locked}"
APP_PORT="${APP_PORT:-8082}"
DIAG_PORT="${DIAG_PORT:-6062}"
WORK_ITEMS="${WORK_ITEMS:-16}"
WORK_DURATION="${WORK_DURATION:-100ms}"
MAX_ITEMS="${MAX_ITEMS:-512}"
MUTEX_FRACTION="${MUTEX_FRACTION:-1}"

case "${1:-up}" in
up)
  [ "$MODE" = locked ] || [ "$MODE" = unlocked ] || die "MODE must be locked or unlocked, got '$MODE'"

  start compute "$APP_PORT" ./"$BIN_DIR"/compute \
    -addr ":$APP_PORT" -diag-addr ":$DIAG_PORT" -mode "$MODE" \
    -work-items "$WORK_ITEMS" -work-duration "$WORK_DURATION" \
    -max-items "$MAX_ITEMS" -mutex-profile-fraction "$MUTEX_FRACTION"

  wait_http "http://localhost:$APP_PORT/healthz" 10 || die "compute healthz never passed"
  # Both reveals come from the diagnostics port, so its readiness is checked like
  # any other dependency rather than discovered at capture time.
  wait_http "http://localhost:$DIAG_PORT/debug/pprof/" 10 || die "pprof endpoint never came up on :$DIAG_PORT"
  wait_http "http://localhost:$DIAG_PORT/metrics" 10 || die "/metrics never came up on :$DIAG_PORT"

  record_mode "$MODE"

  echo
  log "demo 3 ready in MODE=$MODE (${WORK_ITEMS} items x ${WORK_DURATION})"
  echo "     application  http://localhost:$APP_PORT/compute"
  echo "     stats        http://localhost:$APP_PORT/stats"
  echo "     metrics      http://localhost:$DIAG_PORT/metrics"
  echo "     mutex        curl -o mutex.pb.gz http://localhost:$DIAG_PORT/debug/pprof/mutex"
  echo "     trace        curl -o trace.out \"http://localhost:$DIAG_PORT/debug/pprof/trace?seconds=8\""
  if [ "$MODE" = locked ]; then
    echo "     the mutex is held across expensiveWork — one task runs at a time, process-wide"
  else
    echo "     the mutex covers storeResult only — tasks compute in parallel"
  fi
  ;;

down)
  stop_all
  ;;

status)
  echo "demo 3 ports:"
  status "$APP_PORT" "$DIAG_PORT"
  ;;

*)
  die "usage: MODE=locked|unlocked $0 {up|down|status}"
  ;;
esac
