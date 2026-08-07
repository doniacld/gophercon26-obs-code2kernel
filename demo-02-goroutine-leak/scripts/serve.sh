#!/usr/bin/env bash
# Start demo 2's server in one shape, and wait until it answers.
#
#   ./scripts/serve.sh --metrics-only    /metrics alone      (act 1)
#   ./scripts/serve.sh                   /metrics and pprof  (act 2)
#   ./scripts/serve.sh --fixed           the corrected handler (act 3)
#
# The default is the version with the bug, and it is the default deliberately: the
# flags are typed on screen during the talk, and `--broken` in act 1 would announce
# the ending before the first command has run. Only act 3 names a mode, because by
# then naming it is the point.
#
# Whatever ran before is killed first. That is also the only way to clean up after
# the broken mode: leaked goroutines are blocked forever, so nothing short of
# ending the process reclaims them — the honest version of "restart fixes it".
set -uo pipefail

cd "$(dirname "$0")/.."

MODE=broken
PPROF=true
for arg in "$@"; do
	case "$arg" in
	--fixed) MODE=fixed ;;
	--broken) MODE=broken ;;
	--metrics-only) PPROF=false ;;
	*)
		echo "usage: $0 [--fixed] [--metrics-only]" >&2
		exit 2
		;;
	esac
done

DIAG=http://localhost:6061
METRICS="$DIAG/metrics"
PPROF_URL="$DIAG/debug/pprof/goroutine?debug=1"
BIN=/tmp/demo2-server

pkill -f "$BIN" 2>/dev/null
# Wait for the port to be free, otherwise the next bind races the old process's
# exit and the server dies with "address already in use".
for _ in $(seq 1 50); do
	curl -s -o /dev/null --max-time 0.2 "$METRICS" || break
	sleep 0.1
done

go build -o "$BIN" . || exit 1
"$BIN" -mode "$MODE" -pprof="$PPROF" >/tmp/demo2-server.log 2>&1 &

# Every endpoint the caller was promised, not just one: a half-ready server would
# fail mid-sentence, on stage, between two commands that both looked fine.
for _ in $(seq 1 50); do
	if curl -s -o /dev/null --max-time 0.2 "$METRICS"; then
		[ "$PPROF" = true ] || break
		curl -s -o /dev/null --max-time 0.2 "$PPROF_URL" && break
	fi
	sleep 0.1
done || true

# The mode is not echoed back either, for the same reason it is not a flag in act 1.
if [ "$PPROF" = true ]; then
	echo "ready: app :8081 /work   diag :6061 /metrics /debug/pprof"
else
	echo "ready: app :8081 /work   diag :6061 /metrics"
fi
