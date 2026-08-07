# Demo 2 — a goroutine leak: detected by a metric, diagnosed by a profile
#
#   make before   the leak
#   make after    the same requests, no leak
#
# app  :8081  GET /work
# diag :6061  /metrics (go_goroutines) and /debug/pprof/*
#
# before and after are the two self-contained runs: each starts the server, sends
# the requests and prints both signals. That is the whole demo in two commands, and
# it is what rehearse.sh and the artifacts are built on.
#
# On stage it is told in three acts instead — the metric, the profile, the fix —
# because the middle one is a code change the audience should watch happen. Same
# commands, same numbers, paced by the speaker: see ../scripts/LIVE.md.

.PHONY: before after live live-pprof live-fix clean test build down status help

before: ## the leak: 100 cancelled requests, ~100 goroutines left behind
	@./scripts/run-demo.sh broken

after: ## the fix: the same requests, goroutine count back to baseline
	@./scripts/run-demo.sh fixed

live: ## live act 1: the gauge climbs, and pprof is not there to ask
	@../scripts/live.sh 2-1-metric

live-pprof: ## live act 2: add pprof, the same load, the [chan send] stack
	@../scripts/live.sh 2-2-pprof

live-fix: ## live act 3: the fix, the same load, the profile again
	@../scripts/live.sh 2-3-fix

test: ## the leak and the fix, asserted without a stopwatch
	go test -race ./...

clean: ## stop the server and remove the binary
	@pkill -f demo2-server 2>/dev/null || true
	@rm -f /tmp/demo2-server

# The rest is here only so the repository-wide loops in ../Makefile (build, down,
# status, clean) have something to call for this demo. The demo itself is the two
# targets above.
build:
	@go build -o /tmp/demo2-server .

down: clean

status:
	@echo "demo 2:"
	@if curl -s -o /dev/null --max-time 1 http://localhost:6061/metrics; then \
		echo "  :8081 app, :6061 diag up"; else echo "  :8081 app, :6061 diag down"; fi

help:
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t14
