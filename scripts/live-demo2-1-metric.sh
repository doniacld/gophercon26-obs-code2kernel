#!/usr/bin/env bash
# Demo 2, act 1, live — a service, some traffic, and one metric.
#
# The live twin of scripts/cast-demo2-metric.sh: same commands, same order, paced
# by the speaker pressing Enter.
#
# The server is started with -pprof=false, so /metrics really is all it exposes.
# That is where most services are, and this act stays inside that limit: it shows
# a number that should not be moving, moving.
#
# Narration is command titles only — no reading of the output, no diagnosis. What
# is deliberately absent from the screen:
#
#   the timings          the curl is on screen; what --max-time means to a 90ms
#                        handler is the speaker's line in act 2, not a caption here
#   the word "leak"      the audience should reach it from the gauge
#   any pprof output     act 2 adds pprof as a code change, and that change is
#                        only interesting if the room has felt the lack of it
#
# It also does not end by asking for a profile and being refused. A 404 on a slide
# reads as a broken demo, whatever the narration says.
#
# The gauge is read three times: idle, after the traffic, and again once the traffic
# is over. The third reading is the act, and the scrape carries its own argument:
# the second line says "gauge", so a snapshot that went up when work arrived should
# come down when the work is gone. It does not.
#
# The startup line names no mode. `--metrics-only` is honest about what is missing;
# `broken` would give away the ending in the first command on screen.
#
#   ./scripts/live-demo2-1-metric.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-02-goroutine-leak"
source ../scripts/live-lib.sh
source ../scripts/demo2-common.sh

clear
banner "Demo 2 — act 1: the metric" \
	"an HTTP service on :8081, and its /metrics endpoint on :6061"

step "Start the service"
liverun "./scripts/serve.sh --metrics-only" 'ready:'

step "Get number of goroutines metric"
liverun "$GAUGE" '^go_goroutines '

step "Sending traffic on /work"
liverun "$LOAD"

step "Get number of goroutines metric"
liverun "$GAUGE" '^go_goroutines '

step "Get number of goroutines metric again"
liverun "$GAUGE" '^go_goroutines '

printf '\n%sLeave it running: ./scripts/live-demo2-2-pprof.sh continues from here.%s\n' "$GREY" "$NC"
