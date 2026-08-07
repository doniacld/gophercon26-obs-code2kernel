#!/usr/bin/env bash
# Demo 1 screencast — the commands from demo-01-otel-sequential-calls/README.md,
# run for real, in the order the README's "Run it" section gives them.
#
# Prerequisite: make up (Jaeger) at the repository root.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-01-otel-sequential-calls"
source ../scripts/cast-lib.sh

clear
banner "Demo 1 — a dashboard endpoint and three services behind it" \
	"frontend GET /dashboard  ->  profile-service, recommendation-service, inventory-service"

run "make broken" 'MODE=broken|one after another'

run "make one" '"total_ms"|"sum_of_dependency_ms"|<- '
run "make load" 'avg=|throughput'

run "make trace" 'concurrency factor|never overlapped'

run "make fixed" 'MODE=fixed|concurrently'

run "make one" '"total_ms"|"slowest_dependency_ms"|<- '

run "make load" 'avg=|throughput'

run "make trace" 'concurrency factor|at the same time'

closing "Same three spans. Only their arrangement on the timeline changed."
