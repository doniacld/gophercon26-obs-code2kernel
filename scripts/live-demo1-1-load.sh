#!/usr/bin/env bash
# Demo 1, part 1, live — one request, then the trace in a real Jaeger UI.
#
# The live twin of scripts/cast-demo1-load.sh: same commands, same order, but the
# speaker presses Enter between steps and the link at the end leads to a real
# waterfall the audience can be walked through and clicked around in.
#
# Starts Jaeger and the four services itself. Nothing on screen names the cause —
# the waterfall is what should say it first.
#
#   ./scripts/live-demo1-1-load.sh          run it
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-01-otel-sequential-calls"
source ../scripts/live-lib.sh

JAEGER=${JAEGER_URL:-http://localhost:16686}
# Deep link straight into the frontend's traces: service preselected, this mode's
# tag applied, sorted longest-first. One click, no form to fill in on stage.
TAGS='%7B%22demo.mode%22%3A%22broken%22%7D'
SEARCH="$JAEGER/search?service=frontend&tags=$TAGS&sortBy=LONGEST_FIRST&limit=20&lookback=1h"

clear
banner "Demo 1 — a dashboard endpoint and three services behind it" \
	"frontend GET /dashboard  ->  profile-service, recommendation-service, inventory-service"

prepare before

step "Sending one request on /dashboard"
# -o /dev/null drops the response body. It is a kilobyte of dependency payloads
# that nobody reads from six rows back, and the timings it carries are the ones
# the waterfall is about to show properly. The request and response headers stay:
# they are what makes it visibly one HTTP call to one endpoint.
liverun "curl -sv -o /dev/null http://localhost:8080/dashboard" '< HTTP'

step "The trace in Jaeger"
showlink "$SEARCH"

printf '\n%sExpand the root span and look at how the three children are laid out.%s\n' "$BOLD" "$NC"
printf '%sLeave the services running: ./scripts/live-demo1-2-fix.sh continues from here.%s\n' "$GREY" "$NC"
