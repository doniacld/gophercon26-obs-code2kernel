#!/usr/bin/env bash
# Run demo 2 in one mode: start the server, send 100 requests that all cancel
# before the work finishes, and ask two different tools what happened.
#
#   ./scripts/run-demo.sh broken
#   ./scripts/run-demo.sh fixed
#
# Two endpoints, two questions, and the order matters:
#
#   /metrics                    go_goroutines — how many goroutines exist
#   /debug/pprof/goroutine      what those goroutines are doing
#
# The metric is the detection: it is a Prometheus gauge, it is the kind of thing a
# dashboard alerts on, and it can only tell you a number is climbing. The profile
# is the diagnosis: it names the state, the function and the line. Nothing here
# computes either one — the gauge is scraped from /metrics and the stacks come out
# of ?debug=2.
set -uo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-broken}"
[ "$MODE" = broken ] || [ "$MODE" = fixed ] || {
	echo "usage: $0 broken|fixed" >&2
	exit 2
}

APP=http://localhost:8081
DIAG=http://localhost:6061
PPROF="$DIAG/debug/pprof/goroutine"
METRICS="$DIAG/metrics"
REQUESTS=100

BOLD=$'\033[1m' GREY=$'\033[90m' NC=$'\033[0m'

# The Prometheus runtime gauge, straight out of the scrape. No fallback: if
# /metrics is not answering or the collector is not registered, that is a broken
# demo and it should say so instead of printing a blank.
goroutines() {
	local metric
	metric="$(curl -fsS "$METRICS" | awk '$1 == "go_goroutines" { print $1, $2 }')"
	if [ -z "$metric" ]; then
		echo "go_goroutines metric not found at $METRICS" >&2
		exit 1
	fi
	printf '%s\n' "$metric"
}

# Build, restart, wait until both endpoints answer. Shared with the live scripts so
# a self-contained run and a staged one start the same process the same way.
if [ "$MODE" = fixed ]; then
	./scripts/serve.sh --fixed >/dev/null || exit 1
else
	./scripts/serve.sh >/dev/null || exit 1
fi

printf '\n%s%s%s\n' "$BOLD" "$(echo "$MODE" | tr '[:lower:]' '[:upper:]')" "$NC"

printf '\nRuntime metric before:\n'
goroutines

if [ "$MODE" = broken ]; then
	printf '\nSending %d requests that time out before work completes...\n' "$REQUESTS"
else
	printf '\nSending the same %d cancelled requests...\n' "$REQUESTS"
fi

# --max-time 0.02 against 90ms of work: every client gives up long before the
# result exists, which is the condition the bug needs. xargs -P 20 keeps 20 in
# flight so the whole batch takes about a second.
seq 1 "$REQUESTS" | xargs -P 20 -I{} \
	curl -s --max-time 0.02 "$APP/work" >/dev/null 2>&1 || true

# Long enough for every broken worker to finish its 90ms sleep and park on the
# send, and for every fixed worker to notice cancellation and exit. Without the
# wait, both modes would look clean for the wrong reason.
sleep 0.25

printf '\nRuntime metric after:\n'
goroutines

# The metric has done its job and stops here. Everything below comes from the
# profile, which is the only one of the two that can name a line.
#
# debug=2 prints one stanza per goroutine, starting "goroutine N [state]:". Only
# stanzas that are both in [chan send] *and* inside this program's own code count:
# the metrics handler and the profiler have goroutines of their own, and "our
# workers are stuck" is the claim being made.
leaked=$(curl -s "$PPROF?debug=2" | awk '
	/^goroutine [0-9]+ \[/ { stanza = $0; blocked = /\[chan send\]/; ours = 0; next }
	/^$/                   { if (blocked && ours) n++; blocked = 0; next }
	/^main\./              { ours = 1 }
	END                    { if (blocked && ours) n++; print n + 0 }
')

printf '\npprof diagnosis:\n'
if [ "${leaked:-0}" -gt 0 ]; then
	printf '%d goroutines blocked on channel send\n\n' "$leaked"
	# One stanza is the whole diagnosis — the other ninety-nine are identical, which
	# is the point. The directory prefix is stripped and the +0x50 offsets dropped: a
	# projector has room for "server.go:79" and nothing to gain from the absolute
	# path of a laptop. The file and line — the thing to go and fix — are what stays.
	curl -s "$PPROF?debug=2" | awk '
		/^goroutine [0-9]+ \[chan send\]/ { keep = 1 }
		keep                              { print }
		keep && /^$/                      { exit }
	' | sed -e "s|$PWD/||" -e 's/ +0x[0-9a-f]*$//'
	printf '%s(the other %d are the same stack)%s\n' "$GREY" "$((leaked - 1))" "$NC"
else
	printf 'no accumulated application goroutines blocked on channel send\n'
fi
