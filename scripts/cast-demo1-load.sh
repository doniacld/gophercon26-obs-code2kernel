#!/usr/bin/env bash
# Demo 1, part 1 — one request, then the trace in Jaeger.
#
# Two commands and nothing else. No diagnosis on screen: the audience reads the
# waterfall in the browser and says what is wrong before the terminal does.
#
# Prerequisites, both outside the cast so the recording stays short:
#   make up                                    (Jaeger, at the repository root)
#   make -C demo-01-otel-sequential-calls before
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-01-otel-sequential-calls"
source ../scripts/cast-lib.sh

JAEGER=${JAEGER_URL:-http://localhost:16686}
# Deep link straight into the frontend's traces: service preselected, this mode's
# tag applied, sorted longest-first. One click, no form to fill in on stage.
TAGS='%7B%22demo.mode%22%3A%22broken%22%7D'
SEARCH="$JAEGER/search?service=frontend&tags=$TAGS&sortBy=LONGEST_FIRST&limit=20&lookback=1h"

clear
banner "Demo 1 — a dashboard endpoint and three services behind it" \
	"frontend GET /dashboard  ->  profile-service, recommendation-service, inventory-service"

note "Sending one request on /dashboard"
# -s alongside -v silences only the progress meter, which otherwise interleaves
# with the verbose header lines and turns the request into a wall of noise.
#
# -o /dev/null drops the response body: a kilobyte of dependency payloads nobody
# reads from six rows back, carrying the same timings the waterfall is about to
# show properly. The headers stay — they are what makes it visibly one HTTP call.
run "curl -sv -o /dev/null http://localhost:8080/dashboard" '< HTTP'

note "Open the trace in Jaeger"
link "$SEARCH"

closing "Expand the root span and look at how the three children are laid out."
