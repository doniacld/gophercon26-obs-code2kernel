# Demo 4 — the missing time: a CPU profile cannot see what the process was not
# allowed to do.
#
# application  :8083  POST /compute {"jobs":16}, /stats, /throttle, /reset, /healthz
# diagnostics  :6063  /debug/pprof/*
#
#   make before        one request -> seconds, not milliseconds, and no cause given
#   make investigate   CPU profile, then the off-CPU flame graph
#   make after         cpu.stat confirms the throttling, then the corrected quota
#   make full          all three, in order, unattended (Linux + root)
#
# The narrative, in the order the commands produce it:
#
#   1. the request is slow
#   2. the Go CPU profile explains only a small part of the latency
#   3. an off-CPU flame graph shows where time accumulated while NOT running
#   4. cpu.stat confirms the container was CPU-throttled
#
# Step 4 is in `after`, not `investigate`, and the quota is not printed before it.
# cpu.stat names the mechanism outright, so reading it early ends the
# investigation before it starts — the audience would have the answer before
# seeing why a CPU profile could not have given it to them.
#
# Nothing about the Go program changes between before and after. One image, one
# digest, one entrypoint, one request body — only the cgroup quota differs.
#
# `before` and `after` need Docker. `investigate` additionally needs a Linux
# kernel it can load an eBPF program into, plus BCC and the FlameGraph scripts;
# it checks for all of them up front and prints the install commands.

SHELL := /bin/bash

APP_PORT     ?= 8083
DIAG_PORT    ?= 6063
JOBS         ?= 16
CAPTURE_SECS ?= 10

export APP_PORT DIAG_PORT JOBS CAPTURE_SECS FLAMEGRAPH_DIR

.PHONY: help full before investigate after clean status logs test bench \
        up request capture cpu-top offcpu cgroup

help: ## show this help
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t22

# The whole story in one command, for a Linux host or VM that can do all of it.
# Three separate targets are right on stage, where the pauses between them are the
# demo; this one is right when you are validating a machine or capturing artifacts.
full: ## all three steps in order (Linux + root)
	@./scripts/demo4.sh before
	@./scripts/demo4.sh investigate
	@./scripts/demo4.sh after

before: ## the symptom: one slow request, and no cause on screen
	@./scripts/demo4.sh before

investigate: ## CPU profile, then the off-CPU flame graph
	@./scripts/demo4.sh investigate

after: ## cpu.stat confirms the throttling, then the corrected quota
	@./scripts/demo4.sh after

# The same story as one question per command, which is what the live scripts type.
# These print tool output and nothing else — no headings, no commentary — so the
# reading is the speaker's to do out loud. `before`/`investigate`/`after` above
# compose them and add the narration a rehearsal wants.
up: ## start one mode (MODE=baseline|corrected)
	@./scripts/demo4.sh up $(or $(MODE),baseline)

request: ## POST /compute once, and time it
	@./scripts/demo4.sh request

capture: ## sample pprof CPU + BCC offcputime over one window (Linux + root)
	@./scripts/demo4.sh capture

cpu-top: ## the CPU profile, as pprof printed it
	@./scripts/demo4.sh cpu-top

offcpu: ## the off-CPU stacks, grouped by how the request path left the CPU
	@./scripts/demo4.sh offcpu

cgroup: ## cpu.max and cpu.stat for the staged mode, as the kernel wrote them
	@./scripts/demo4.sh cgroup

clean: ## remove containers and generated artifacts
	@./scripts/demo4.sh clean

status: ## ports and the staged mode
	@./scripts/demo4.sh status

logs: ## the staged container's logs
	@docker logs --tail 40 gcdemo-demo4-$$(cat .run/mode 2>/dev/null || echo baseline) 2>&1 \
		|| echo "no container running"

# Runs anywhere: no Docker, no cgroup, no eBPF. Establishes the per-job CPU cost,
# which is the number a correct quota has to be large enough to serve.
#
# ComputeJob, not Compute: the request sends JobRounds-sized jobs, and Compute's
# own benchmark measures DefaultRounds — about twice as long. Both are useful, but
# only one of them is the number the demo quotes, and on stage the screen has to
# agree with the talk track. ComputeJobs is here too as the wall-clock floor.
bench: ## per-job CPU cost, measured without a container
	go test -bench=ComputeJob -benchtime=10x ./internal/hash/

test: ## the work is identical in every mode, under the race detector
	go test -race ./...
