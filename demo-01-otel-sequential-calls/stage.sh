#!/usr/bin/env bash
# Stage driver for demo 1. Invoked by the Makefile; not meant to be run directly.
#
# Usage: MODE=broken|fixed ./stage.sh {up|down|status}
#
# Four processes: three dependencies and one frontend. The dependencies are the
# same binary with different -name/-latency, so the only thing that differs
# between the two modes is the frontend's control flow.

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=../scripts/lib.sh
source ../scripts/lib.sh

MODE="${MODE:-broken}"
FRONTEND_PORT="${FRONTEND_PORT:-8080}"
DIAG_PORT="${DIAG_PORT:-6060}"
PROFILE_PORT="${PROFILE_PORT:-8085}"
RECS_PORT="${RECS_PORT:-8086}"
INVENTORY_PORT="${INVENTORY_PORT:-8087}"
PROFILE_LATENCY="${PROFILE_LATENCY:-180ms}"
RECS_LATENCY="${RECS_LATENCY:-250ms}"
INVENTORY_LATENCY="${INVENTORY_LATENCY:-320ms}"
OTLP_ENDPOINT="${OTLP_ENDPOINT:-localhost:4318}"

case "${1:-up}" in
up)
  [ "$MODE" = broken ] || [ "$MODE" = fixed ] || die "MODE must be broken or fixed, got '$MODE'"

  # Fail early and clearly if the collector is not up. Without this the services
  # start fine, serve traffic fine, and the trace simply never appears — which
  # on stage looks like the demo being broken rather than Jaeger being absent.
  if ! wait_tcp 127.0.0.1 "${OTLP_ENDPOINT##*:}" 3; then
    die "no OTLP collector on $OTLP_ENDPOINT — run 'make up' at the repository root first"
  fi

  start profile-service "$PROFILE_PORT" ./"$BIN_DIR"/dependency \
    -addr ":$PROFILE_PORT" -name profile-service -latency "$PROFILE_LATENCY" \
    -mode "$MODE" -otlp-endpoint "$OTLP_ENDPOINT"

  start recommendation-service "$RECS_PORT" ./"$BIN_DIR"/dependency \
    -addr ":$RECS_PORT" -name recommendation-service -latency "$RECS_LATENCY" \
    -mode "$MODE" -otlp-endpoint "$OTLP_ENDPOINT"

  start inventory-service "$INVENTORY_PORT" ./"$BIN_DIR"/dependency \
    -addr ":$INVENTORY_PORT" -name inventory-service -latency "$INVENTORY_LATENCY" \
    -mode "$MODE" -otlp-endpoint "$OTLP_ENDPOINT"

  start frontend "$FRONTEND_PORT" ./"$BIN_DIR"/frontend \
    -addr ":$FRONTEND_PORT" -diag-addr ":$DIAG_PORT" -mode "$MODE" \
    -profile-url "http://localhost:$PROFILE_PORT/fetch" \
    -recommendation-url "http://localhost:$RECS_PORT/fetch" \
    -inventory-url "http://localhost:$INVENTORY_PORT/fetch" \
    -otlp-endpoint "$OTLP_ENDPOINT"

  # Readiness on every service, not just the frontend: a dependency that has
  # bound its port but not finished starting would turn the first request of the
  # demo into a 502.
  for p in "$PROFILE_PORT" "$RECS_PORT" "$INVENTORY_PORT"; do
    wait_http "http://localhost:$p/healthz" 10 || die "dependency on :$p never became healthy"
  done
  wait_http "http://localhost:$FRONTEND_PORT/healthz" 10 || die "frontend healthz never passed"

  record_mode "$MODE"

  echo
  log "demo 1 ready in MODE=$MODE"
  echo "     dependencies: profile=$PROFILE_LATENCY recommendation=$RECS_LATENCY inventory=$INVENTORY_LATENCY"
  if [ "$MODE" = broken ]; then
    echo "     the three calls are made one after another — expect ~750ms and a staircase"
  else
    echo "     the three calls are made at the same time — expect ~330ms and overlap"
  fi
  ;;

down)
  stop_all
  ;;

status)
  echo "demo 1 ports:"
  status "$FRONTEND_PORT" "$DIAG_PORT" "$PROFILE_PORT" "$RECS_PORT" "$INVENTORY_PORT" 4318 16686
  ;;

*)
  die "usage: MODE=broken|fixed $0 {up|down|status}"
  ;;
esac
