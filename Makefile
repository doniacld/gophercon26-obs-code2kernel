# Inside out: observing Go programs — four demos
#
#   make setup                  check the machine, start Jaeger, build everything
#   make demo1-before           OTel: sequential calls that should overlap
#   make demo2-before           metric + pprof: a goroutine leak
#   make demo3-locked           mutex profile + trace: concurrent is not parallel
#   make demo4-before           eBPF off-CPU: the time a CPU profile cannot see
#   make clean                  stop every process and container, remove output
#
# Each demo has two states. Run the first, look at the signal, then run the second
# and look again — that is the whole shape of every demo here. Demos 1, 2 and 4
# name them before/after, which is what the audience is comparing; demo 3 says
# locked/unlocked. Demo 4 has a third command, investigate, between the two, and
# does not name its cause until after — the quota is the answer.
#
# Request flow, then process resource pressure, then runtime scheduling and
# synchronization, then system-level waiting. Each demo needs a tool the previous
# one could not have used.
#
# The per-demo Makefiles have more: `make -C demo-03-lock-contention help`.

SHELL := /bin/bash

D1 := demo-01-otel-sequential-calls
D2 := demo-02-goroutine-leak
D3 := demo-03-lock-contention
D4 := demo-04-cpu-quota
DEMOS := $(D1) $(D2) $(D3) $(D4)

JAEGER_UI_PORT ?= 16686
OTLP_HTTP_PORT ?= 4318
export JAEGER_UI_PORT OTLP_HTTP_PORT

.PHONY: help setup up down build test bench vet fmt fmt-check clean rehearse status artifacts

help: ## show this help
	@echo "Inside out: observing Go programs — four demos"
	@echo
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t26
	@echo
	@echo "Per-demo detail:  make -C $(D2) help"

# ---------------------------------------------------------------------------
# Setup and teardown
# ---------------------------------------------------------------------------

setup: ## check the machine, start Jaeger, build all four demos
	@./scripts/setup.sh

check: ## check the machine without changing anything
	@./scripts/setup.sh --check

up: ## start Jaeger only (demo 1's single external dependency)
	@docker compose up -d
	@echo "waiting for Jaeger..."
	@until curl -s -o /dev/null --max-time 2 "http://localhost:$(JAEGER_UI_PORT)/api/services"; do sleep 0.5; done
	@echo "Jaeger ready — http://localhost:$(JAEGER_UI_PORT)"

down: ## stop every demo process, leave Jaeger running
	@for d in $(DEMOS); do $(MAKE) -s -C $$d down 2>/dev/null || true; done

build: ## compile every demo
	@for d in $(DEMOS); do echo "==> $$d"; $(MAKE) -s -C $$d build || exit 1; done

# ---------------------------------------------------------------------------
# Demo 1 — OpenTelemetry: the latency that is missing from the trace
# ---------------------------------------------------------------------------

.PHONY: demo1-before demo1-after demo1-broken demo1-fixed demo1-load demo1-trace \
        demo1-compare demo1-down demo1-live demo1-live-fix

# The two live scripts are what runs on stage: one request, then the waterfall in
# a real Jaeger UI, paced by the speaker. casts/ holds the recorded fallback.
demo1-live: ## live act 1: one request to /dashboard, then the trace in Jaeger
	@./scripts/live.sh 1-1-load

demo1-live-fix: ## live act 2: the code change, the same request, the new trace
	@./scripts/live.sh 1-2-fix

demo1-before: ## OTel: the version to be diagnosed
	@$(MAKE) --no-print-directory -C $(D1) before

demo1-after: ## OTel: the corrected version
	@$(MAKE) --no-print-directory -C $(D1) after

demo1-broken: demo1-before ## alias for demo1-before

demo1-fixed: demo1-after ## alias for demo1-after

demo1-load: ## drive demo 1 hard enough to fill its queue
	@$(MAKE) --no-print-directory -C $(D1) load

demo1-trace: ## print the slowest recent trace as a terminal waterfall
	@$(MAKE) --no-print-directory -C $(D1) trace

demo1-compare: ## both waterfalls, one after the other
	@$(MAKE) --no-print-directory -C $(D1) compare

demo1-down:
	@$(MAKE) --no-print-directory -C $(D1) down

# ---------------------------------------------------------------------------
# Demo 2 — a goroutine leak: go_goroutines detects it, pprof diagnoses it
#
# Two targets and nothing else. The gauge is scraped from /metrics and the stacks
# come from /debug/pprof/goroutine, so there is no load generator to build, no
# counters to reset, no /stats to explain — and no Prometheus to run: `curl` and
# `awk` are the whole scrape.
# ---------------------------------------------------------------------------

.PHONY: demo2-before demo2-after demo2-broken demo2-fixed demo2-down \
        demo2-live demo2-live-pprof demo2-live-fix

# On stage the same two runs are told in three acts, because the second one is a
# code change worth watching happen. Same commands, same numbers, speaker-paced.
demo2-live: ## live act 1: the gauge climbs, and pprof is not there to ask
	@./scripts/live.sh 2-1-metric

demo2-live-pprof: ## live act 2: add pprof, the same load, the [chan send] stack
	@./scripts/live.sh 2-2-pprof

demo2-live-fix: ## live act 3: the fix, the same load, the profile again
	@./scripts/live.sh 2-3-fix

demo2-before: ## go_goroutines +100, then the [chan send] stack that explains it
	@$(MAKE) --no-print-directory -C $(D2) before

demo2-after: ## the same requests: the gauge comes back, no stack left blocked
	@$(MAKE) --no-print-directory -C $(D2) after

demo2-broken: demo2-before ## alias for demo2-before

demo2-fixed: demo2-after ## alias for demo2-after

demo2-down:
	@$(MAKE) --no-print-directory -C $(D2) down

# ---------------------------------------------------------------------------
# Demo 3 — lock contention: the mutex profile, then the execution trace
# ---------------------------------------------------------------------------

.PHONY: demo3-locked demo3-unlocked demo3-load demo3-profile-mutex demo3-trace \
        demo3-view demo3-sync demo3-compare demo3-down \
        demo3-before demo3-after demo3-prometheus \
        demo3-live demo3-live-trace demo3-live-fix

# Three parts on stage: metrics stop short, then the tools that do not, then the
# fix. Same load and same commands in parts 1 and 3.
demo3-live: ## live act 1: check pprof
	@./scripts/live.sh 3-1-metrics

demo3-live-trace: ## live act 2: check mutex profile and traces
	@./scripts/live.sh 3-2-trace

demo3-live-fix: ## live act 3: implement the fix
	@./scripts/live.sh 3-3-fix

demo3-prometheus: ## start Prometheus scraping demo 3 every second
	@$(MAKE) --no-print-directory -C $(D3) prometheus

demo3-before: ## locked under sustained load, with the metrics to read
	@$(MAKE) --no-print-directory -C $(D3) before

demo3-after: ## unlocked, identical load, the same metrics
	@$(MAKE) --no-print-directory -C $(D3) after

demo3-locked: ## contention: 16 tasks x 100ms take 1.6s on 11 idle processors
	@$(MAKE) --no-print-directory -C $(D3) locked

demo3-unlocked: ## contention: the same work in 0.1s, same mutex, moved
	@$(MAKE) --no-print-directory -C $(D3) unlocked

demo3-load: ## 8 requests at concurrency 8 — one full round
	@$(MAKE) --no-print-directory -C $(D3) load

demo3-profile-mutex: ## FIRST REVEAL: where contention accumulated
	@$(MAKE) --no-print-directory -C $(D3) profile-mutex

demo3-trace: ## SECOND REVEAL: how it unfolded over time
	@$(MAKE) --no-print-directory -C $(D3) trace

demo3-view: ## open the captured trace in go tool trace
	@$(MAKE) --no-print-directory -C $(D3) view

demo3-sync: ## blocking profile from the trace — Mutex.Lock is the headline
	@$(MAKE) --no-print-directory -C $(D3) sync

demo3-compare: ## locked vs unlocked wall clock for identical work
	@$(MAKE) --no-print-directory -C $(D3) compare

demo3-down:
	@$(MAKE) --no-print-directory -C $(D3) down

# ---------------------------------------------------------------------------
# Demo 4 — the missing time: what a CPU profile cannot see
#
# The CPU profile comes first and is meant to disappoint: it is accurate, and it
# accounts for a fraction of the elapsed time. That is not a failure of pprof — it
# answered "where did this process consume CPU?" correctly. The question actually
# being asked is where the elapsed time went while the process was *not* running,
# and the off-CPU stacks answer that. cpu.stat then names the cause.
#
# Nothing before the last step names the quota. `before` shows a slow request and
# does not say what it runs under, `investigate` gets as far as "runnable and not
# running", and `after` opens with cpu.stat — which is where the hypothesis is
# tested rather than announced.
#
# demo4-investigate needs Linux and root; before and after need only Docker.
# ---------------------------------------------------------------------------

.PHONY: demo4-full demo4-before demo4-investigate demo4-after demo4-down \
        demo4-live-request demo4-live-pprof demo4-live-ebpf demo4-live-cgroup

# Four parts on stage: the elapsed time, the CPU profile, the off-CPU stacks,
# then the cgroup counters and a larger quota.
demo4-live-request: ## live act 1: one request, timed
	@./scripts/live.sh 4-1-request

demo4-live-pprof: ## live act 2: the CPU profile, and how little of the window it covers
	@./scripts/live.sh 4-2-pprof

demo4-live-ebpf: ## live act 3: off-CPU time, from the kernel (Linux + root)
	@./scripts/live.sh 4-3-ebpf

demo4-live-cgroup: ## live act 4: the cgroup counters, then a larger quota
	@./scripts/live.sh 4-4-cgroup

demo4-full: ## all three demo 4 steps in order, unattended (Linux + root)
	@$(MAKE) --no-print-directory -C $(D4) full

demo4-before: ## the symptom: one slow request, and no cause on screen
	@$(MAKE) --no-print-directory -C $(D4) before

demo4-investigate: ## CPU profile, then the off-CPU flame graph (Linux + root)
	@$(MAKE) --no-print-directory -C $(D4) investigate

demo4-after: ## cpu.stat confirms the throttling, then the corrected quota
	@$(MAKE) --no-print-directory -C $(D4) after

demo4-down:
	@$(MAKE) --no-print-directory -C $(D4) clean

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

test: ## every unit test, with the race detector
	go test -race ./...

bench: ## every benchmark
	go test -bench=. -benchtime=10x ./...

vet: ## go vet across the module
	go vet ./...

fmt: ## gofmt every file
	gofmt -w .

fmt-check: ## fail if anything is unformatted
	@out=$$(gofmt -l .); \
	if [ -n "$$out" ]; then echo "unformatted:"; echo "$$out"; exit 1; fi; \
	echo "gofmt clean"

# Shell scripts are as much a part of these demos as the Go code, and a syntax
# error in one only shows up when it runs — on stage.
.PHONY: shellcheck
shellcheck: ## parse every shell script
	@for f in scripts/*.sh */stage.sh */scripts/*.sh; do bash -n "$$f" && echo "  ok $$f"; done

# The pre-conference check. Everything except demo 1 (needs Jaeger) and demo 4's
# eBPF capture (needs Linux + root) runs unattended here.
rehearse: build ## run every demo end to end and print the headline numbers
	@./scripts/rehearse.sh

status: ## who owns every port this repository uses
	@for d in $(DEMOS); do $(MAKE) -s -C $$d status 2>/dev/null || true; done
	@echo "jaeger:"
	@if curl -s -o /dev/null --max-time 1 "http://localhost:$(JAEGER_UI_PORT)/api/services"; then \
		echo "  :$(JAEGER_UI_PORT) up"; else echo "  :$(JAEGER_UI_PORT) down"; fi

artifacts: ## regenerate every capturable artifact into artifacts/
	@./scripts/capture-artifacts.sh

# ---------------------------------------------------------------------------

# artifacts/ deliberately survives. It holds the prerecorded captures that are
# the fallback when a live capture fails, and deleting them as part of routine
# cleanup would remove the safety net at exactly the wrong moment. `make
# clean-artifacts` is the explicit way to drop them.
clean: ## stop every process and container, remove build output (keeps artifacts/)
	@for d in $(DEMOS); do $(MAKE) -s -C $$d clean 2>/dev/null || true; done
	@docker compose down 2>/dev/null || true
	@echo "clean — artifacts/ kept; 'make clean-artifacts' removes those too"

.PHONY: clean-artifacts
clean-artifacts: ## delete the captured profiles and traces in artifacts/
	@rm -rf artifacts
	@echo "artifacts removed — 'make artifacts' regenerates them"
