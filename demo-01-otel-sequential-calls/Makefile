# Demo 1 — OpenTelemetry: independent calls made sequentially
#
# frontend               :8080  GET /dashboard     diagnostics :6060
# profile-service        :8085  GET /fetch         180ms
# recommendation-service :8086  GET /fetch         250ms
# inventory-service      :8087  GET /fetch         320ms
# jaeger                 :16686 UI                 OTLP/HTTP :4318  (root Makefile)
#
#   make broken   one   trace   -> ~755ms, three spans in a staircase
#   make fixed    one   trace   -> ~325ms, three spans overlapping
#
# The instrumentation is identical in both modes. Only the control flow changes,
# and the waterfall is what makes that visible.

SHELL := /bin/bash

MODE              ?= broken
FRONTEND_PORT     ?= 8080
DIAG_PORT         ?= 6060
PROFILE_PORT      ?= 8085
RECS_PORT         ?= 8086
INVENTORY_PORT    ?= 8087
PROFILE_LATENCY   ?= 180ms
RECS_LATENCY      ?= 250ms
INVENTORY_LATENCY ?= 320ms
REQUESTS          ?= 20
CONCURRENCY       ?= 5
OTLP_ENDPOINT     ?= localhost:4318
JAEGER_URL        ?= http://localhost:16686
ARTIFACTS         ?= ../artifacts

export MODE FRONTEND_PORT DIAG_PORT PROFILE_PORT RECS_PORT INVENTORY_PORT
export PROFILE_LATENCY RECS_LATENCY INVENTORY_LATENCY OTLP_ENDPOINT

# The mode the staged services are running in, recorded by stage.sh, so a capture
# started from a fresh make process cannot mislabel its artifact.
RUNNING = $(shell cat .run/mode 2>/dev/null || echo $(MODE))

.PHONY: help build build-services before after broken fixed up down status one \
        load trace trace-broken trace-fixed compare capture logs test clean

help: ## show this help
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t26

build: build-services bin/loadgen ## compile the frontend, the dependency binary and the load generator

# The four services on their own. `before` and `after` stop here rather than at
# build: they send one request each, and a `go build -o bin/loadgen` line on the
# screen invites the question "what load?" about a generator they never run.
build-services: ## compile the frontend and the shared dependency binary
	@mkdir -p bin
	go build -o bin/frontend   ./cmd/frontend
	go build -o bin/dependency ./cmd/dependency

# before/after and broken/fixed are the same two states under two vocabularies.
# On screen the states are "before" and "after", because that is what the audience
# is comparing. Everywhere a mode is recorded — the demo.mode span attribute,
# .run/mode, artifact directories, rehearse.sh — it stays broken/fixed, so traces
# captured before this rename still mean what they say.
before: build-services ## start the version to be diagnosed (MODE=broken)
	@MODE=broken ./stage.sh up

after: build-services ## start the corrected version (MODE=fixed)
	@MODE=fixed ./stage.sh up

broken: before ## alias for before
fixed: after ## alias for after

up: build ## start in MODE (default broken)
	@./stage.sh up

down: ## stop all four processes
	@./stage.sh down

status: ## show which process owns each port
	@./stage.sh status

# One request is the whole demo. The trace of a single uncontended request shows
# the staircase without any load-related noise to explain away.
one: ## a single request, with its total time
	@curl -s -w '\n  <- %{time_total}s total\n' "http://localhost:$(FRONTEND_PORT)/dashboard"

# bin/loadgen rather than build: `before` and `after` only build the services, so
# the generator is compiled by whoever actually needs it. Without this dependency
# a `before; load` sequence fails on a missing binary.
load: bin/loadgen ## $(REQUESTS) requests at concurrency $(CONCURRENCY)
	@./bin/loadgen -url "http://localhost:$(FRONTEND_PORT)/dashboard" \
		-requests $(REQUESTS) -concurrency $(CONCURRENCY)

bin/loadgen: cmd/loadgen/main.go
	@mkdir -p bin
	go build -o bin/loadgen ./cmd/loadgen

# The sleep is not cosmetic: the SDK batches with a 1s timeout, so querying
# immediately returns a half-exported trace with a missing root and a waterfall
# full of holes that have nothing to do with the demo.
#
# --mode $(RUNNING) is not optional either. Jaeger keeps every trace of the
# session, the broken ones are by definition the slowest, and --slowest without a
# mode filter therefore shows the staircase again after you have switched to
# fixed. Showing a "before" trace while saying "after" is the worst thing this
# demo can do, so the filter is applied on the mode stage.sh recorded.
trace: ## print the slowest trace from the currently running mode
	@sleep 2
	@python3 ../scripts/dump-trace.py frontend --jaeger "$(JAEGER_URL)" \
		--slowest --mode "$(RUNNING)"

trace-broken: ## print the slowest trace recorded by a broken build
	@sleep 2
	@python3 ../scripts/dump-trace.py frontend --jaeger "$(JAEGER_URL)" --slowest --mode broken

trace-fixed: ## print the slowest trace recorded by a fixed build
	@sleep 2
	@python3 ../scripts/dump-trace.py frontend --jaeger "$(JAEGER_URL)" --slowest --mode fixed

# Save the waterfall as text. Jaeger's memory storage dies with the container, so
# a text capture is the only fallback that survives a restart.
capture: ## write the current mode's waterfall into artifacts/
	@mkdir -p "$(ARTIFACTS)/demo1-$(RUNNING)-trace"
	@sleep 2
	@python3 ../scripts/dump-trace.py frontend --jaeger "$(JAEGER_URL)" --slowest \
		--mode "$(RUNNING)" --no-color > "$(ARTIFACTS)/demo1-$(RUNNING)-trace/waterfall.txt"
	@echo "wrote $(ARTIFACTS)/demo1-$(RUNNING)-trace/waterfall.txt"

# The full before/after in one command, for rehearsal and for the moment when a
# live sequence has gone sideways and you need the result on screen quickly.
compare: build ## run broken, then fixed, and print both waterfalls
	@MODE=broken ./stage.sh up >/dev/null
	@echo "=== MODE=broken ==="
	@$(MAKE) --no-print-directory load | tail -3
	@$(MAKE) --no-print-directory trace-broken
	@echo
	@MODE=fixed ./stage.sh up >/dev/null
	@echo "=== MODE=fixed ==="
	@$(MAKE) --no-print-directory load | tail -3
	@$(MAKE) --no-print-directory trace-fixed

logs: ## tail every service log
	@tail -n 20 .run/frontend.log .run/profile-service.log \
		.run/recommendation-service.log .run/inventory-service.log

test: ## equivalence, cancellation and timing tests
	go test -race ./...

clean: down ## stop everything and remove build output
	rm -rf bin .run
