# Demo 3 — lock contention: the mutex profile says where, the trace says why
#
# compute     :8082  GET /compute?items=16&duration=100ms (POST /process), /stats, /reset
# diagnostics :6062  /metrics, /debug/pprof/*  (mutex, block, trace), /debug/flightrecorder
#
#   make prometheus               -> a scraper, then `make before` and `make after`
#   make locked  one              -> 16 tasks x 100ms take 1.6s, speedup 1.0
#   make unlocked one              -> the same work takes 0.2s, speedup ~8
#   make profile-mutex            -> FIRST REVEAL: where contention accumulated
#   make trace  view              -> SECOND REVEAL: how it unfolded over time
#
# The order matters. The mutex profile is a total: sync.(*Mutex).Lock with tens of
# seconds beside it. It says nothing about what happened in between, and the
# execution trace is what fills that in.

SHELL := /bin/bash

MODE           ?= locked
APP_PORT       ?= 8082
DIAG_PORT      ?= 6062
TRACE_PORT     ?= 9091
PPROF_PORT     ?= 9092
WORK_ITEMS     ?= 16
WORK_DURATION  ?= 100ms
MAX_ITEMS      ?= 512
MUTEX_FRACTION ?= 1

# 8 requests at concurrency 8 is exactly one round: every request starts at once
# and the run ends when the slowest finishes. Broken mode takes 8 x 16 x 100ms =
# 12.8s of queued CPU work to get through, so a larger REQUESTS multiplies that
# by whole rounds — 24 requests is a 38-second wait on stage. One round is enough
# to saturate the lock and it fits inside a sentence.
REQUESTS       ?= 8
CONCURRENCY    ?= 8
TRACE_SECONDS  ?= 8
# `make sync` derives a blocking profile from the trace, and a derived profile
# counts only waits that both start and end inside the window. At 16 x 100ms a
# queued goroutine waits up to 12s, so an 8-second trace contains no completed
# mutex waits and the profile comes back without sync.(*Mutex).Lock in it. 25s
# comfortably covers two rounds. The trace UI itself needs no such margin — 8s of
# timeline is plenty to look at — so the two capture lengths differ on purpose.
SYNC_SECONDS   ?= 25
RAMP           ?= 1
ARTIFACTS      ?= ../artifacts

export MODE APP_PORT DIAG_PORT WORK_ITEMS WORK_DURATION MAX_ITEMS MUTEX_FRACTION

# The mode the staged service is actually running in, recorded by stage.sh.
#
# MODE only says what the *next* `make up` would start. `make unlocked` followed by
# `make trace` runs a second make process where MODE is back to its default, so
# labelling the capture with MODE would write trace-locked.out from the unlocked
# build. Capture targets label by RUNNING, never by MODE.
RUNNING = $(shell cat .run/mode 2>/dev/null || echo $(MODE))

# Which saved artifact the read-only targets open. An explicit `MODE=locked` on
# the command line wins — you can inspect yesterday's trace with nothing running.
# Otherwise follow whatever is staged, so `make unlocked trace view` reads the file
# it just wrote instead of the default.
ifeq ($(origin MODE), command line)
READ = $(MODE)
else
READ = $(RUNNING)
endif

.PHONY: help build locked unlocked up down status one load stats reset \
        profile-mutex profile-block profile-cpu mutex-web trace trace-locked trace-unlocked \
        view view-locked view-unlocked sync sync-derive sync-long sched capture compare \
        logs bench test clean

help: ## show this help
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t26

build: ## compile the service and the load generator
	@mkdir -p bin
	go build -o bin/compute ./cmd/compute
	go build -o bin/loadgen ./cmd/loadgen

locked: build ## start with the mutex held across expensiveWork
	@MODE=locked ./stage.sh up

unlocked: build ## start with the mutex held only for storeResult
	@MODE=unlocked ./stage.sh up

up: build ## start in MODE (default locked)
	@./stage.sh up

down: ## stop the service
	@./stage.sh down

status: ## show which process owns each port
	@./stage.sh status

# One request, formatted. The whole diagnosis in eight lines of JSON, and it needs
# no profiler: wall_ms against cpu_time_ms is the ratio that matters, and
# peak_working is how many tasks were ever computing at once.
one: ## a single request, with the speedup the service computed for itself
	@curl -s "http://localhost:$(APP_PORT)/compute?items=$(WORK_ITEMS)&duration=$(WORK_DURATION)" \
		| python3 -m json.tool 2>/dev/null || \
		curl -s "http://localhost:$(APP_PORT)/compute"

# Counters are reset first so the numbers belong to this run and not to whatever
# ran before it. Reading a stale peak on stage is the same class of mistake as
# showing a mislabelled artifact.
load: reset ## $(REQUESTS) requests at concurrency $(CONCURRENCY)
	@./bin/loadgen -url "http://localhost:$(APP_PORT)/compute" \
		-requests $(REQUESTS) -concurrency $(CONCURRENCY) \
		-items $(WORK_ITEMS) -duration $(WORK_DURATION)
	@$(MAKE) --no-print-directory stats

stats: ## the service's own contention counters
	@curl -s "http://localhost:$(APP_PORT)/stats" | python3 -c \
		'import json,sys; d=json.load(sys.stdin); \
		print("  peak concurrent tasks %d of %d processors   goroutines %d" % \
			(d["peak_working"], d["gomaxprocs"], d["goroutines"])); \
		print("  lock wait  total %.0fms   avg per task %.1fms" % \
			(d["total_lock_wait_ms"], d["avg_lock_wait_ms"])); \
		print("  store      %d writes across %d keys   requests %d" % \
			(d["store_writes"], d["stored_keys"], d["requests"]))' 2>/dev/null \
		|| curl -s "http://localhost:$(APP_PORT)/stats"

reset: ## zero the service's counters
	@curl -s "http://localhost:$(APP_PORT)/reset" >/dev/null 2>&1 || true

# --- load helpers ----------------------------------------------------------
#
# Every capture must happen under load: a mutex profile of an idle process is
# empty and a trace of one is a blank timeline. Backgrounding the load and
# stopping it afterwards is factored out so no capture target can forget.
define load-bg
	@test -f .run/mode || { echo "nothing staged — run 'make locked' or 'make unlocked' first"; exit 1; }
	@mkdir -p $(ARTIFACTS) .run
	@if kill -0 $$(cat .run/loadgen.pid 2>/dev/null) 2>/dev/null; then \
		touch .run/loadgen.borrowed; \
	else \
		rm -f .run/loadgen.borrowed; \
		./bin/loadgen -url "http://localhost:$(APP_PORT)/compute" \
			-requests 100000 -concurrency $(CONCURRENCY) \
			-items $(WORK_ITEMS) -duration $(WORK_DURATION) >/dev/null 2>&1 & \
		echo $$! > .run/loadgen.pid; \
		sleep $(RAMP); \
	fi
endef

# Stop the load this capture started — and only that one. `make load-start` leaves
# a load running on purpose so a speaker can talk over a live graph, and a capture
# target firing in the middle of that must not silently end it. Without the
# borrowed marker, load-bg would overwrite the pid file and orphan the speaker's
# loadgen for the rest of the session.
define load-stop
	@if [ -f .run/loadgen.borrowed ]; then \
		rm -f .run/loadgen.borrowed; \
	else \
		kill $$(cat .run/loadgen.pid 2>/dev/null) 2>/dev/null || true; \
		rm -f .run/loadgen.pid; \
	fi
endef

# --- first reveal: the mutex profile ---------------------------------------
#
# runtime.SetMutexProfileFraction must have been called or this comes back empty.
# The service does it at startup and logs the value, because "the mutex profile is
# empty" is otherwise the single most confusing failure in this demo.
#
# The units deserve saying out loud: contention *delay*, summed across goroutines.
# Tens of seconds inside an 8-second window is normal and correct — 100 blocked
# goroutines accumulate wall-clock time 100× faster than the clock runs.
profile-mutex: ## FIRST REVEAL: where contention accumulated -> artifacts/demo3-mutex-profile/
	$(load-bg)
	@mkdir -p "$(ARTIFACTS)/demo3-mutex-profile"
	@echo "capturing mutex profile under load (mode=$(RUNNING))..."
	@curl -s -o "$(ARTIFACTS)/demo3-mutex-profile/mutex-$(RUNNING).pb.gz" \
		"http://localhost:$(DIAG_PORT)/debug/pprof/mutex"
	@curl -s "http://localhost:$(APP_PORT)/stats" \
		> "$(ARTIFACTS)/demo3-mutex-profile/stats-$(RUNNING).json"
	$(load-stop)
	@echo
	@go tool pprof -top -nodecount=12 \
		"$(ARTIFACTS)/demo3-mutex-profile/mutex-$(RUNNING).pb.gz"
	@echo
	@echo "  contention delay, summed across goroutines — not elapsed time"

# The annotated source view. Stronger than -top for an audience: it puts the
# accumulated delay against the actual line that held the lock.
mutex-web: ## open the mutex profile in the pprof web UI
	@test -s "$(ARTIFACTS)/demo3-mutex-profile/mutex-$(READ).pb.gz" || \
		{ echo "no mutex-$(READ).pb.gz — run 'make profile-mutex' first"; exit 1; }
	go tool pprof -http=:$(PPROF_PORT) "$(ARTIFACTS)/demo3-mutex-profile/mutex-$(READ).pb.gz"

# Wider than the mutex profile: channels, selects, WaitGroup and mutexes. The one
# to reach for when you do not yet know which primitive is responsible.
profile-block: ## the block profile — all blocking, not just mutexes
	$(load-bg)
	@mkdir -p "$(ARTIFACTS)/demo3-mutex-profile"
	@curl -s -o "$(ARTIFACTS)/demo3-mutex-profile/block-$(RUNNING).pb.gz" \
		"http://localhost:$(DIAG_PORT)/debug/pprof/block"
	$(load-stop)
	@echo
	@go tool pprof -top -nodecount=12 \
		"$(ARTIFACTS)/demo3-mutex-profile/block-$(RUNNING).pb.gz"

# The contrast that motivates the whole demo: the CPU profile is nearly identical
# in both modes, because the same function burns the same cycles. It localises the
# work and says nothing at all about the serialization.
profile-cpu: ## capture a CPU profile instead — deliberately unhelpful here
	$(load-bg)
	@mkdir -p "$(ARTIFACTS)/demo3-mutex-profile"
	@curl -s -o "$(ARTIFACTS)/demo3-mutex-profile/cpu-$(RUNNING).pb.gz" \
		"http://localhost:$(DIAG_PORT)/debug/pprof/profile?seconds=$(TRACE_SECONDS)"
	$(load-stop)
	@echo
	@go tool pprof -top -nodecount=10 \
		"$(ARTIFACTS)/demo3-mutex-profile/cpu-$(RUNNING).pb.gz"

# --- second reveal: the execution trace -----------------------------------
#
# SECONDS defaults to TRACE_SECONDS for the visual timeline. `make sync` calls this
# with SECONDS=$(SYNC_SECONDS) because a derived blocking profile needs whole waits
# inside the window — see the comment on `sync` below.
SECONDS ?= $(TRACE_SECONDS)

trace: ## SECOND REVEAL: $(TRACE_SECONDS)s execution trace under load
	$(load-bg)
	@mkdir -p "$(ARTIFACTS)/demo3-$(RUNNING)-trace"
	@echo "capturing $(SECONDS)s execution trace under load (mode=$(RUNNING))..."
	@curl -s -o "$(ARTIFACTS)/demo3-$(RUNNING)-trace/trace.out" \
		"http://localhost:$(DIAG_PORT)/debug/pprof/trace?seconds=$(SECONDS)"
	$(load-stop)
	@ls -lh "$(ARTIFACTS)/demo3-$(RUNNING)-trace/trace.out" | awk '{print "  wrote " $$9 " (" $$5 ")"}'
	@echo "  go tool trace -http=:$(TRACE_PORT) $(ARTIFACTS)/demo3-$(RUNNING)-trace/trace.out"

trace-locked: ## start locked and capture its trace
	@$(MAKE) --no-print-directory locked
	@$(MAKE) --no-print-directory trace

trace-unlocked: ## start unlocked and capture its trace
	@$(MAKE) --no-print-directory unlocked
	@$(MAKE) --no-print-directory trace

# go tool trace serves a local web UI and picks its own port unless told. Pin it
# so the browser tab is predictable during a talk.
view: ## open the captured trace in go tool trace
	@test -s "$(ARTIFACTS)/demo3-$(READ)-trace/trace.out" || \
		{ echo "no demo3-$(READ)-trace/trace.out — run 'make trace' first"; exit 1; }
	go tool trace -http=:$(TRACE_PORT) "$(ARTIFACTS)/demo3-$(READ)-trace/trace.out"

view-locked: ## open the locked trace
	@$(MAKE) --no-print-directory view MODE=locked

view-unlocked: ## open the unlocked trace
	@$(MAKE) --no-print-directory view MODE=unlocked

# `go tool trace` can emit pprof-shaped profiles from a trace. This is the
# strongest single piece of evidence that needs no browser: blocking time
# attributed to the call that blocked.
#
# It requires a trace window long enough to contain whole blocks. A derived
# profile counts a wait only once it has both started AND ended inside the trace,
# so at 16 x 100ms a goroutine can wait 12s and an 8-second trace captures no
# completed waits at all — sync.(*Mutex).Lock is then absent and the profile looks
# like the bug is gone. Hence SYNC_SECONDS > TRACE_SECONDS, and hence the warning
# below. The mutex profile has no such constraint, which is one good reason it
# goes first.
# This is the projector-failed fallback, so it has to produce the evidence on its
# own. Reusing whatever trace.out happens to be on disk is not good enough: the
# documented live sequence runs `make trace` first, which writes an 8-second trace,
# and a 12-second wait cannot fit inside it. So: derive, check, and if the window
# was too short, recapture once at SYNC_SECONDS and derive again. Slow — 25 seconds
# of silence — but a fallback that prints a suggestion instead of the evidence is
# not a fallback.
#
# Only recapture when reading the mode that is actually staged. With an explicit
# MODE=locked against a stopped service you are inspecting yesterday's artifact,
# and there is nothing to capture from.
sync: ## blocking profile derived from the trace — sync.(*Mutex).Lock is the headline
	@test -s "$(ARTIFACTS)/demo3-$(READ)-trace/trace.out" || \
		$(MAKE) --no-print-directory trace SECONDS=$(SYNC_SECONDS)
	@$(MAKE) --no-print-directory sync-derive
	@if ! go tool pprof -top -nodecount=10 "$(ARTIFACTS)/demo3-$(READ)-trace/sync.pprof" 2>/dev/null \
		| grep -q 'sync.(\*Mutex).Lock'; then \
		if [ "$(READ)" = "$(RUNNING)" ] && [ -f .run/mode ]; then \
			echo; \
			echo "  no completed mutex waits in that window — recapturing $(SYNC_SECONDS)s so whole"; \
			echo "  waits fit inside the trace. Takes $(SYNC_SECONDS)s."; \
			$(MAKE) --no-print-directory trace SECONDS=$(SYNC_SECONDS) >/dev/null; \
			echo; \
			$(MAKE) --no-print-directory sync-derive; \
		else \
			echo "  note: no completed mutex waits in this window — start the demo and run"; \
			echo "  'make sync-long'"; \
		fi; \
	fi

# Derive and print, without judging whether the window was long enough. Split out
# so `sync` can run it a second time after a longer capture. Deliberately does not
# write a .txt: `capture` owns artifacts/demo3-*-trace/sync-top.txt at nodecount=20,
# and this target must not quietly truncate a committed artifact to 10 lines.
sync-derive:
	@go tool trace -pprof=sync "$(ARTIFACTS)/demo3-$(READ)-trace/trace.out" \
		> "$(ARTIFACTS)/demo3-$(READ)-trace/sync.pprof" 2>/dev/null
	@go tool pprof -top -nodecount=10 "$(ARTIFACTS)/demo3-$(READ)-trace/sync.pprof" 2>/dev/null

sync-long: ## capture a $(SYNC_SECONDS)s trace and derive the blocking profile from it
	@$(MAKE) --no-print-directory trace SECONDS=$(SYNC_SECONDS)
	@$(MAKE) --no-print-directory sync

sched: ## scheduler-latency profile from the trace: runnable-but-not-running time
	@test -s "$(ARTIFACTS)/demo3-$(READ)-trace/trace.out" || \
		{ echo "no demo3-$(READ)-trace/trace.out — run 'make trace' first"; exit 1; }
	@go tool trace -pprof=sched "$(ARTIFACTS)/demo3-$(READ)-trace/trace.out" \
		> "$(ARTIFACTS)/demo3-$(READ)-trace/sched.pprof" 2>/dev/null
	@go tool pprof -top -nodecount=10 "$(ARTIFACTS)/demo3-$(READ)-trace/sched.pprof" 2>/dev/null

# The .pb.gz profiles and trace.out are binary, machine-specific and gitignored.
# These text summaries are small enough to commit and are the fallback that
# survives a laptop swap: if the tools will not run on stage, the numbers are
# still on disk.
# The trace is captured at SYNC_SECONDS, not TRACE_SECONDS: this target's job is
# to produce artifacts that still show the bug tomorrow, and a sync profile with
# no completed mutex waits in it would not.
capture: profile-mutex ## both reveals + committable text summaries
	@$(MAKE) --no-print-directory trace SECONDS=$(SYNC_SECONDS)
	@go tool pprof -top -nodecount=20 \
		"$(ARTIFACTS)/demo3-mutex-profile/mutex-$(RUNNING).pb.gz" \
		> "$(ARTIFACTS)/demo3-mutex-profile/top-$(RUNNING).txt" 2>&1
	@go tool trace -pprof=sync "$(ARTIFACTS)/demo3-$(RUNNING)-trace/trace.out" \
		> "$(ARTIFACTS)/demo3-$(RUNNING)-trace/sync.pprof" 2>/dev/null
	@go tool pprof -top -nodecount=20 "$(ARTIFACTS)/demo3-$(RUNNING)-trace/sync.pprof" \
		> "$(ARTIFACTS)/demo3-$(RUNNING)-trace/sync-top.txt" 2>&1
	@curl -s "http://localhost:$(APP_PORT)/compute" \
		> "$(ARTIFACTS)/demo3-$(RUNNING)-trace/one-request.json" 2>/dev/null || true
	@echo "captured mutex profile and trace for mode=$(RUNNING)"
	@echo "  $(ARTIFACTS)/demo3-mutex-profile/top-$(RUNNING).txt"
	@echo "  $(ARTIFACTS)/demo3-$(RUNNING)-trace/sync-top.txt"

# Both modes, one request each, side by side. Survives a failed live capture.
compare: build ## locked vs unlocked wall clock for identical work
	@MODE=locked ./stage.sh up >/dev/null 2>&1
	@echo "=== MODE=locked ==="
	@curl -s "http://localhost:$(APP_PORT)/compute" | tr ',' '\n' \
		| grep -E 'wall_ms|cpu_time_ms|lock_wait_ms|peak_working|speedup|critical_pct|parallelism'
	@MODE=unlocked ./stage.sh up >/dev/null 2>&1
	@echo
	@echo "=== MODE=unlocked ==="
	@curl -s "http://localhost:$(APP_PORT)/compute" | tr ',' '\n' \
		| grep -E 'wall_ms|cpu_time_ms|lock_wait_ms|peak_working|speedup|critical_pct|parallelism'
	@echo
	@echo "Same work, same checksums. Only the lock placement differs."

# --- the metrics view: before and after ------------------------------------
#
# One target per mode, each self-contained: stop whatever ran last, start this
# mode, wait for /metrics, drive it for WORKLOAD_SECONDS, print the queries.
#
# The two are sequential, not parallel, and they have to be: both bind :8082 and
# :6062, so Prometheus scrapes one target that changes underneath it. Run `make
# before`, read the graphs, then `make after` and read the same graphs again.
# The mode label is there so a range long enough to span both still separates
# them, but nothing needs it if you look while each half is running.
#
# Every parameter below is shared by both halves — same requests, same
# concurrency, same items, same duration, same GOMAXPROCS. That is the entire
# claim of the demo: nothing changed except where the lock is taken.
PROM_PORT       ?= 9090
PROM_CONTAINER  ?= gcdemo-demo3-prometheus
PROM_IMAGE      ?= prom/prometheus:v2.54.1
WORKLOAD_SECONDS ?= 45

# Which spelling of "the host's :6062" the scrape config gets. Prometheus in a
# container cannot reach localhost; on the host it cannot reach
# host.docker.internal. PROM_TARGET can be set explicitly for anything unusual.
PROM_TARGET ?= host.docker.internal:$(DIAG_PORT)

.PHONY: before after prometheus prometheus-stop load-start workload-stop metrics queries

before: ## locked mode under sustained load, with Prometheus scraping it
	@$(MAKE) --no-print-directory mode-under-load MODE=locked

after: ## unlocked mode, same load, same everything else
	@$(MAKE) --no-print-directory mode-under-load MODE=unlocked

.PHONY: mode-under-load
mode-under-load:
	@./stage.sh down >/dev/null 2>&1 || true
	@$(MAKE) --no-print-directory up MODE=$(MODE)
	@echo "waiting for $(MODE) /metrics ..."
	@for i in $$(seq 1 40); do \
		curl -sf "http://localhost:$(DIAG_PORT)/metrics" >/dev/null && break; \
		sleep 0.25; \
	done
	@curl -sf "http://localhost:$(DIAG_PORT)/metrics" >/dev/null \
		|| { echo "/metrics never came up on :$(DIAG_PORT)"; exit 1; }
	$(load-bg)
	@echo "driving $(MODE) for $(WORKLOAD_SECONDS)s at concurrency $(CONCURRENCY), $(WORK_ITEMS) items x $(WORK_DURATION) ..."
	@end=$$(( $$(date +%s) + $(WORKLOAD_SECONDS) )); \
	while [ $$(date +%s) -lt $$end ]; do \
		sleep 5; \
		printf "  cpu %s   workers %s   waiting %ss\n" \
			"$$(./scripts/cores.sh $(DIAG_PORT))" \
			"$$(curl -s http://localhost:$(DIAG_PORT)/metrics | awk '/^demo3_active_workers/ {print $$2}')" \
			"$$(curl -s http://localhost:$(DIAG_PORT)/metrics | awk '/^demo3_mutex_wait_seconds_total/ {printf "%.0f", $$2}')"; \
	done
	@echo
	@$(MAKE) --no-print-directory stats
	@echo
	@$(MAKE) --no-print-directory queries
	@echo "  the load is still running (mode=$(MODE)) — 'make workload-stop' ends it"

queries: ## the Prometheus expressions this demo reads
	@echo "Prometheus  http://localhost:$(PROM_PORT)/graph      metrics  http://localhost:$(DIAG_PORT)/metrics"
	@echo
	@echo "  rate(process_cpu_seconds_total[30s])"
	@echo "      CPU cores the process is consuming. ~1 means one core's worth of"
	@echo "      work is getting done, whatever the machine has available."
	@echo "  go_sched_gomaxprocs_threads"
	@echo "      cores it is allowed to use."
	@echo "  100 * rate(process_cpu_seconds_total[30s]) / go_sched_gomaxprocs_threads"
	@echo "      share of the process's own CPU allowance — not of the machine."
	@echo "  demo3_active_workers"
	@echo "      workers inside a batch right now."
	@echo "  rate(demo3_mutex_wait_seconds_total[30s])"
	@echo "      seconds of waiting per second: how many workers are queued, on average."
	@echo "  histogram_quantile(0.95, sum by (le) (rate(demo3_request_duration_seconds_bucket[30s])))"
	@echo "      p95 batch latency."
	@echo "  rate(demo3_items_processed_total[30s])"
	@echo "      throughput, in items per second."

metrics: ## the application metrics, as scraped
	@curl -s "http://localhost:$(DIAG_PORT)/metrics" | grep -E '^demo3_|^process_cpu_seconds_total|^go_goroutines|^go_sched_gomaxprocs_threads'

# load-start and workload-stop as a pair, for the live scripts: the speaker needs
# the load running while they talk over a graph, which is a different shape from
# the capture targets that start and stop it around one curl.
load-start: ## start sustained background load and return
	$(load-bg)
	@echo "load running: concurrency $(CONCURRENCY), $(WORK_ITEMS) items x $(WORK_DURATION)"

workload-stop: ## stop the background load started by before/after/load-start
	@kill $$(cat .run/loadgen.pid 2>/dev/null) 2>/dev/null || true
	@rm -f .run/loadgen.pid .run/loadgen.borrowed

# Prometheus, in the same shape as the repository's Jaeger: one container, one
# config file, no volume and no state to survive into the next rehearsal. No
# Grafana — the expression browser draws the two lines this demo needs.
prometheus: ## start Prometheus scraping :$(DIAG_PORT) every second
	@mkdir -p .run
	@sed 's|__TARGET__|$(PROM_TARGET)|' prometheus.yml > .run/prometheus.yml
	@docker rm -f $(PROM_CONTAINER) >/dev/null 2>&1 || true
	@docker run -d --name $(PROM_CONTAINER) \
		--add-host=host.docker.internal:host-gateway \
		-p $(PROM_PORT):9090 \
		-v "$(PWD)/.run/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
		$(PROM_IMAGE) >/dev/null
	@echo "prometheus  http://localhost:$(PROM_PORT)/graph   scraping $(PROM_TARGET) every 1s"
	@echo "            http://localhost:$(PROM_PORT)/targets  should show demo3 UP"

prometheus-stop: ## remove the Prometheus container
	@docker rm -f $(PROM_CONTAINER) >/dev/null 2>&1 || true

logs: ## tail the service log
	@tail -n 20 .run/compute.log

bench: ## the same comparison offline
	go test -bench=. -benchtime=10x ./internal/work/

test: ## correctness in both modes, under the race detector
	go test -race ./...

clean: down prometheus-stop workload-stop ## stop everything and remove build output
	rm -rf bin .run
