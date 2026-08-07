#!/usr/bin/env bash
# Demo 2 screencast — the two commands from demo-02-goroutine-leak/README.md, run
# for real.
#
# No external dependency: one local Go process, started and stopped by the make
# targets themselves.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-02-goroutine-leak"
source ../scripts/cast-lib.sh

clear
banner "Demo 2 — an HTTP service, and the metric it exposes" \
	"100 requests, each abandoned by its client after 20 ms."

run "make before" 'go_goroutines|goroutines blocked on channel send|main.handleWorkBroken'
run "make after" 'go_goroutines|no accumulated application goroutines'

closing "A request ending does not automatically stop the goroutines it created."
