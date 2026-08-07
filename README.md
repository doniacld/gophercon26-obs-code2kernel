# Inside out: observing Go programs

Four self-contained demos for a conference talk about finding out what a Go
service is actually doing. Each one starts with a service that is measurably
wrong, shows the observation that explains it, and then shows the same service
fixed — with the same load, so the evidence can be compared rather than described.

Every number in this repository and in the per-demo READMEs was measured, not
estimated. Where something could not be measured on the authoring machine — demo
4's eBPF capture, which needs Linux — it says which machine produced it.

```bash
make setup          # check the machine, start Jaeger, build everything
make demo1-broken   # then look at the trace
make demo1-fixed    # then look again
```

## What each demo shows

| Demo | Symptom | Main evidence | Root cause | Fix | Main lesson |
|---|---|---|---|---|---|
| **1 — OTel sequential calls** | High request latency | Trace waterfall | Independent calls made sequentially | `errgroup.WithContext` | Trace structure reveals control flow |
| **2 — Goroutine leak** | Nothing: the process just grows | `go_goroutines` to detect, goroutine profile to diagnose | Worker started with `context.Background()`, blocked forever on a channel send | Propagate `r.Context()`, buffer the channel, guard the send | A request ending does not automatically stop the goroutines it created |
| **3 — Lock contention** | Low effective parallelism | Mutex profile and Go trace | Large critical section | Move work outside the lock | Concurrent code may still serialize |
| **4 — eBPF off-CPU** | High latency, and the CPU profile explains only part of it | Off-CPU flame graph, then `cpu.stat` | A CPU quota far below measured demand | A quota sized from measured demand — not the removal of the quota | A CPU profile only sees work while the process is running |

The measured headline for each, on an Apple M3 Pro with `GOMAXPROCS=11`:

| Demo | broken | fixed |
|---|---|---|
| 1 | 766 ms average, 6.5 req/s | 323 ms, 15.5 req/s — same three spans, rearranged |
| 2 | `go_goroutines` +100, all in `[chan send]` on one line | the same requests, gauge back to baseline |
| 3 | 16 × 100 ms tasks in 1.6 s, 1 task computing at a time | 102.6 ms, 16 at a time — **15.6×**, identical checksums |
| 4 | 7.0 s for ~1.2 core-seconds; 2.39 s of CPU samples in a 10.11 s window | 415 ms, identical digest — only the cgroup quota changed |

## The progression

The four demos answer four distinct questions, in the order you would actually
ask them:

```
OpenTelemetry           Where is request latency accumulating?
pprof                   What is this process holding on to, and why?
Go execution trace      Why are goroutines failing to progress in parallel?
eBPF off-CPU            Where does elapsed time go while code is not running?
```

```
Request flow → Process resource pressure → Runtime scheduling and
synchronization → System-level waiting
```

Each step widens the aperture — your spans, then your process, then your runtime,
then the kernel — and each step loses context. By demo 4 there is no request ID,
no goroutine, no business meaning, only threads and the reasons they stopped.
That trade is the point of the talk.

1. **Demo 1 — OpenTelemetry.** You control the instrumentation, and both modes
   emit *exactly the same spans*. Only their arrangement on the timeline changes.
   A waterfall shows a staircase where there should have been a stack, which is
   something no latency metric can express.
2. **Demo 2 — a metric, then pprof.** This is the one demo that needs two tools,
   and the split is the lesson. `go_goroutines` is what a dashboard alerts on: it
   detects that goroutines are accumulating and can say nothing about why. The
   goroutine profile groups by stack, so a hundred goroutines parked on the same
   line is the first thing in its output. *The metric tells you what is growing;
   the profile tells you where it is stuck.*
3. **Demo 3 — the execution trace.** The mutex profile says *where* contention
   accumulated. It cannot say that sixteen goroutines ran strictly one at a time
   on eleven idle processors. Only the trace preserves the ordering, and the
   ordering is the bug.
4. **Demo 4 — eBPF off-CPU.** The CPU profile is accurate and it accounts for a
   fraction of the elapsed time: 2.39 s of samples inside a 10.11 s window, all of
   it in `sha256`. That is not a failure of `pprof` — it answered "where did this
   process consume CPU?" correctly. The question actually being asked is where the
   elapsed time went while the process was *not* running, and that measurement has
   to come from outside, from the kernel that descheduled the threads. `cpu.stat`
   then names the cause.

The tools disagree in interesting ways, which is why all four demos exist:

| | 1 · trace | 2 · pprof | 3 · exec trace | 4 · off-CPU |
|---|---|---|---|---|
| Needs instrumentation | yes | no | no | no |
| Sees blocked time | only if you span it | **no** | yes | yes |
| Sees goroutine ordering | no | no | **yes** | no |
| Sees outside the process | across services | no | no | **yes** |
| Knows the business context | **yes** | partly | partly | no |
| Needs root | no | no | no | **yes** |
| Runs in production | yes | yes | briefly | yes |

## Layout

```
gophercon26-obs-code2kernel/
├── README.md                    this file
├── Makefile                     make demoN-broken / demoN-fixed / demoN-live / clean
├── docker-compose.yml           Jaeger — the only external dependency, demo 1 only
├── scripts/
│   ├── LIVE.md                  what runs on stage, act by act
│   ├── live-demoN-*.sh          the scripts run on stage, paced by the speaker
│   ├── cast-demoN*.sh           the same sequences, recorded into casts/
│   ├── setup.sh                 preflight: toolchain, ports, docker, build
│   ├── rehearse.sh              run every demo, check it still makes its numbers
│   ├── capture-artifacts.sh     regenerate artifacts/ + REHEARSAL.md
│   ├── dump-trace.py            print a Jaeger trace as a terminal waterfall
│   └── lib.sh                   shared process/readiness helpers for the demos
├── internal/                    shared: diag server, http server, load generator
├── artifacts/                   fallback captures, one directory per artifact kind
├── casts/                       asciicasts — terminal-only fallback, replayable
├── videos/                      screen recordings of the live scripts
├── demo-01-otel-sequential-calls/
├── demo-02-goroutine-leak/
├── demo-03-lock-contention/
└── demo-04-cpu-quota/
```

Demos 1, 3 and 4 have the same shape: `cmd/`, `internal/`, `stage.sh`, `Makefile`,
`README.md`. Demo 2 is deliberately smaller — one `server.go`, one script, two
make targets — because the whole demo is a handler and a goroutine profile, and
scaffolding around it would only be something else to explain on stage.

Each README carries the measured before/after numbers, the exact commands, a 3–5
minute speaker flow, what the tool reveals and what it does not, and its own
troubleshooting section. Read those for detail; this file is the map.

There are three ways to watch a demo, in descending order of preference:
[`scripts/LIVE.md`](scripts/LIVE.md) runs it, [`videos/`](videos/README.md) shows
it being run, and [`casts/`](casts/README.md) replays it in a terminal when a
projector will not show a browser.

## Ports

Fixed and non-overlapping, so a demo can never accidentally answer for another
one.

| Port | Demo | What |
|---|---|---|
| 8080 / 6060 | 1 | frontend / pprof |
| 8085 · 8086 · 8087 | 1 | profile · recommendation · inventory services (180 / 250 / 320 ms) |
| 8081 / 6061 | 2 | work service / `/metrics` + pprof |
| 8082 / 6062 | 3 | compute / pprof + trace |
| 8083 / 6063 | 4 | compute service / pprof |
| 16686 / 4318 | 1 | Jaeger UI / OTLP-HTTP |
| 9092 · 9094 | 3 · 4 | `pprof -http` web UIs |
| 9091 · 9093 | 3 · 4 | `go tool trace` web UIs |

`make status` shows who holds each one. If something else on your machine wants
4318 or 16686:

```bash
OTLP_HTTP_PORT=14318 JAEGER_UI_PORT=26686 make setup
make demo1-broken OTLP_ENDPOINT=localhost:14318 JAEGER_URL=http://localhost:26686
```

## Requirements

- **Go 1.26+.** Demo 3 uses `runtime/trace.FlightRecorder` (1.25+) and the tests
  use `testing.B.Loop` (1.24+).
- **Docker + compose**, for demo 1's Jaeger and for demo 4 — whose subject is a
  cgroup, and a container is how you get one. Demos 2 and 3 need nothing beyond
  the Go toolchain.
- **curl** and **python3** — fetching profiles and printing trace waterfalls.
- **Linux** for demo 4's eBPF capture: root, and a kernel with BTF or headers.
  Everything else in this repository runs on macOS and Linux alike.
- Optional: **graphviz** for `pprof -web`, and
  [FlameGraph](https://github.com/brendangregg/FlameGraph) for demo 4's SVG.

`make check` verifies all of this and changes nothing.

### macOS

Demos 1, 2 and 3 run natively, and so do demo 4's `make demo4-before` and `make
demo4-after`. `make demo4-investigate` does not: BCC compiles its programs against
the running kernel's headers, and Docker Desktop's linuxkit VM ships BTF but no
headers — no `/lib/modules/$(uname -r)/build`, no `CONFIG_IKHEADERS`. Verified,
not assumed. Use a Linux VM:

```bash
limactl start --name=ebpf template://ubuntu-lts
limactl shell ebpf
sudo apt-get update && sudo apt-get install -y bpfcc-tools linux-headers-$(uname -r) docker.io docker-compose-v2
git clone https://github.com/brendangregg/FlameGraph ~/FlameGraph

cd gophercon26-obs-code2kernel/demo-04-cpu-quota
make before
FLAMEGRAPH_DIR=~/FlameGraph make investigate
make after
```

Multipass works the same way. If the VM's `go` is older than this module's `go`
directive, install a current tarball from <https://go.dev/dl/> — `make
investigate` checks for this before it spends a capture window on it. See
[demo 4's README](demo-04-cpu-quota/README.md#macos-cannot-run-the-ebpf-step-and-the-reason-is-specific).

## Live-talk sequence

Every demo follows the same ten steps, and each fits in 3–5 minutes. The shape is
deliberately identical so the audience learns the rhythm once and can then spend
its attention on the tool rather than on what you are doing.

> 1. explain the symptom · 2. run broken · 3. deterministic load · 4. one key
> observable · 5. ask the audience what they infer · 6. reveal the profile or
> trace · 7. show the faulty code · 8. switch to fixed · 9. the same workload ·
> 10. compare the evidence

### Demo 1 — independent calls made sequentially (4 min)

```bash
make demo1-broken     # 2. start broken
make demo1-load       # 3. deterministic load
                      # 4. symptom: 766 ms average, 6.5 req/s
make demo1-trace      # 6. the waterfall — three child spans in a staircase
make demo1-fixed      # 8. errgroup.WithContext
make demo1-load       # 9. same load
make demo1-trace      # 10. the same three spans, now overlapping. 323 ms.
```

The line to land: *both modes emit exactly the same spans. The only thing that
changed is their arrangement on the timeline, and that arrangement was the bug.*

### Demo 2 — a goroutine leak (3 min)

```bash
make demo2-before     # 100 requests that give up after 20ms. go_goroutines 7 -> 107
make demo2-after      # the same requests. go_goroutines 7 -> 7
```

The gauge is a real Prometheus scrape of `/metrics`; the stacks under it are
`/debug/pprof/goroutine?debug=2`. Nothing is counted by the server, and no
Prometheus server is needed — `curl | awk` is the whole scrape.

The line to land: *the metric tells us what is growing; the profile tells us where
it is stuck.* The handler was correct and returned on time — the leak is in what it
left behind, and `[chan send]` on `server.go:176` names the line to go and fix.

### Demo 3 — concurrent is not parallel (5 min)

```bash
make demo3-locked     # 2
make demo3-load       # 3+4. 16 × 100 ms tasks in 1.6 s on 11 idle processors
make demo3-profile-mutex   # 6. FIRST REVEAL: 948 s of contention delay
make demo3-trace           # 6. SECOND REVEAL: how it unfolded over time
make demo3-view            # the goroutine view, if the projector cooperates
make demo3-unlocked   # 8. compute first, lock only to store
make demo3-load       # 9+10. 102.6 ms, peak_working 1 → 16, same checksums
```

The line to land: *the mutex profile told me where time accumulated. Only the
trace showed me that sixteen goroutines ran one at a time — and the order was the
bug.*

### Demo 4 — the elapsed time no CPU profile can see (5 min)

Three acts, because the investigation is the demo. One question per command, and
each command prints tool output and nothing else:

Every command is typed for real, no `make` on screen — the same as demo 2 typing
`curl … | grep go_goroutines`:

```bash
make demo4-live          # docker compose up, then the same curl twice: 7.1 s for
                         #   ~1.2 core-seconds of arithmetic
                         # go test -bench: ~70 ms of CPU per job, no container
                         # "no lock, no I/O, no sleep — what do you profile?"
make demo4-live-offcpu   # ./scripts/load.sh 25 & and the pprof curl &, so both
                         #   captures cover the same 10 s
                         # offcputime-bpfcc -p $(docker inspect …) in front of them
                         # go tool pprof -top: 2.3 s of samples in a 10.5 s window
                         # ./scripts/offcpu.sh: 17.3 s in the request path, all of it
                         #   preempted mid-computation, no syscall — plus the SVG
                         # ends on the hypothesis, not the cause
make demo4-live-quota    # cat cpu.max, then cat cpu.stat either side of one request
                         #   — the quota named for the first time, and the delta is
                         #   ~70 periods with ~70 throttled
                         # then the corrected quota and the identical request:
                         #   403 ms, 5 periods, 0 throttled, same digest
```

That the commands are real matters more here than elsewhere: the finding is that
after an eBPF program and a flame graph, the thing which names the cause is a
*file*, and `docker exec … cat /sys/fs/cgroup/cpu.stat` says so by itself where
`make cgroup` would hide it. Two short scripts are the exception, for the reason
demo 3 has `cores.sh`: `load.sh` is a loop that has to run in the background, and
`offcpu.sh` is awk over folded stacks.

Nothing in acts 1 and 2 names the quota. It is the answer, and the audience is
meant to arrive at it from the profiles; act 3 reads `cpu.stat` against the
container that is still under the wrong quota to test the hypothesis rather than to
announce it. That rule is also why the mode is called `baseline` rather than
`throttled` — the container name and the compose profile are both on screen in the
first command.

The line to land: *the CPU profile is not broken. It answered where CPU went, and
it was right. The question was where the elapsed time went.*

The unpaced equivalents are `make demo4-before`, `make demo4-investigate` and
`make demo4-after`: the same commands with the narration added, right for a
rehearsal. `demo4-investigate` (and so act 2) needs Linux and root; the others
need only Docker. On macOS act 2 prints
[`artifacts/demo4/offcpu-summary.md`](artifacts/demo4/offcpu-summary.md) instead —
a real capture, kept for exactly this reason.

## Failure-proofing the live demos

Everything in this section exists because a demo that fails on stage is worse
than a slide.

### Rehearse on the machine you will use

```bash
make check        # toolchain, ports, docker — changes nothing
make rehearse     # runs every demo and asserts it still makes its numbers
```

`make rehearse` is the only check that means anything. It runs gofmt, vet and the
full race-enabled test suite, then starts each demo, drives load through it,
captures the signal, and asserts the headline claim. It reports skips loudly — a
skip is a demo you have not proven here.

Do this the evening before, on conference wifi, on battery. Then do it again in
the room.

### Prerecorded artifacts as a fallback

```bash
make artifacts    # regenerate everything into artifacts/, ~2 minutes
```

One directory per artifact kind, matching the four demos:

```
artifacts/
├── demo1-broken-trace/      demo1-fixed-trace/
├── demo2-goroutine-profile/
├── demo3-mutex-profile/     demo3-locked-trace/  demo3-unlocked-trace/
├── demo4/                   cpu-top.txt, cpu-stat.txt, offcpu-summary.md
└── REHEARSAL.md             a dated record of the numbers your machine produced
```

The binary captures are **not committed** — several megabytes each, specific to
the machine and Go version that produced them, and a stale one invites you to
explain numbers your code no longer produces. The directories, their `.gitkeep`
files and the small text summaries *are* committed — about 110 KB in total, so a
fresh clone shows what a capture produces and the numbers survive a laptop swap.

Demo 4's off-CPU capture cannot be reproduced on macOS at all, so
[`artifacts/demo4/offcpu-summary.md`](artifacts/demo4/offcpu-summary.md) carries
its totals, the stack that matters, the `cpu.stat` counters and the VM it came
from. It is the one artifact in this repository that is a written record rather
than a regenerable file.

If a live capture fails, open the saved one:

```bash
cat artifacts/demo1-broken-trace/waterfall.txt
cat artifacts/demo2-goroutine-profile/goroutine-before.txt
go tool trace artifacts/demo3-locked-trace/trace.out
cat artifacts/demo4/cpu-top.txt artifacts/demo4/offcpu-summary.md
```

`make clean` deliberately leaves `artifacts/` alone; `make clean-artifacts` is the
explicit way to drop it.

Demo 3's benchmarks are the most reliable fallback in the repository: no ports,
no services, no Docker, no timing sensitivity.

### Readiness checks, never sleeps

`scripts/lib.sh` starts every process the same way: launch it, poll the port until
it accepts a connection, poll `/healthz` until it answers, then **assert that the
process holding the port is the one just launched**. A stale process answering for
a fresh one is the worst failure mode available, because the demo appears to work
and the numbers are simply from the previous build. If the PIDs do not match, the
demo refuses to start and says so.

Multi-process demos wait on each dependency in order. Demo 1 starts its three
backend services and waits for `/healthz` on each before the frontend exists —
staged the other way round, the demo opens with a 502, and a connection error is a
different story from a slow response. Demo 4 waits for its container's `/healthz`
too, and sends one unprinted warm-up request: the first request into a cold
container pays for page faults and runtime start-up, which under a quarter of a
core is a large fraction of the latency being measured.

Each `stage.sh` also records which mode it started in, so `make demo3-unlocked`
followed by `make demo3-trace` cannot write a locked-labelled artifact from an
unlocked build. Mislabelled artifacts are worse than missing ones.

### Predictable ports and honest cleanup

```bash
make status       # who owns what right now
make down         # stop the demos, leave Jaeger up
make clean        # stop everything, remove bin/ and .run/
```

`make clean` stops every process and container this repository started — and
nothing it did not. No demo needs a machine restart, holds a kernel resource after
exit, or leaves a container behind; every demo has a `reset` that zeroes its
counters without a restart.

### Minimal external dependencies

One container, for one demo. Demos 2, 3 and 4 are plain Go processes observed with
tools that ship with Go: nothing to pull, nothing to configure, no public
internet. Demo 1 needs Jaeger, and its `stage.sh` fails immediately with a clear
message if the collector is absent rather than starting successfully and producing
no trace.

There is no Prometheus *server* and no Kubernetes. Demo 2 exposes a real
Prometheus endpoint — `go_goroutines` on `/metrics`, from the standard
`client_golang` runtime collector — because the detect-then-diagnose split is its
whole point, but it is scraped with `curl` and `awk`. Running the server, a scrape
config and a second UI would add three things to go wrong on stage without
changing anything the audience sees; where a demo needs a counter that no standard tool provides it keeps its own
and serves it on `/stats`. Demo 2 has no such endpoint — every number it shows is
already in `/debug/pprof/goroutine`.

Every delay in these demos is a fixed constant — 180/250/320 ms in demo 1, 90 ms
per unit of work in demo 2, 100 ms per task in demo 3. Demo 4 has no delay at all —
its workload is a fixed count of SHA-256 rounds, and the latency is entirely the
quota. There is no randomness anywhere, and every request count and concurrency is
fixed, with no ramp and no think time.

### Know which numbers are machine-dependent

- **Demo 3's speedup is bounded by `GOMAXPROCS`.** 15.6× on eleven processors; on
  a 4-core machine expect about 4×. `make check` prints your GOMAXPROCS and warns
  if it is low. The `peak_working` counter (1 versus 16) is the machine-independent
  statement of the same bug.
- **Demo 2's leaked-goroutine count is exact: 100 requests, 100 goroutines.** The
  `go_goroutines` baseline (7 here) depends on the Go version, the metrics handler
  and how many connections are still closing, so read the *delta*, not the
  absolute.
- **Demo 4's latencies scale with the host, but its ratio does not.** 7.1 s to
  403 ms here; the machine-independent statement is `nr_throttled` against
  `nr_periods` — ~70 of ~70 for one request — and the identical digest across both
  runs. Read it as a delta: `cpu.stat` is cumulative since the container started,
  so a single read is diluted by every idle period since boot, and an idle process
  cannot be throttled. Act 3 `cat`s the file, sends one request, and `cat`s again.
- **Demo 4's corrected quota can still show one throttled period on a 4-core host**,
  because the corrected quota asks for 3 cores and the runtime's own threads clip
  a period. The script says so rather than letting it read as a failed fix.
- **Demo 4's raw off-CPU total exceeds wall clock** — 43.20 s in a 10 s window —
  because it is summed across threads and most of it is the runtime's own
  voluntary sleeping. The request path's share, and how it left the CPU, is the
  signal. Total off-CPU time is a diagnostic, not an objective.
- **Run-to-run variance is real.** Demo 3's `Mutex.Lock` total was 25.0 s and
  26.8 s in two consecutive captures of the same window. A different number in
  rehearsal is not a broken demo.

### If a tool refuses to cooperate

| Situation | Fallback |
|---|---|
| Browser or projector will not show `go tool trace` | `make demo3-sync` — the same evidence, in the terminal |
| Jaeger UI unreachable | `make demo1-trace` — the waterfall as text, from Jaeger's query API |
| `pprof -web` fails (no graphviz) | every profile in these demos is read as text; nothing needs graphviz |
| No Linux for demo 4 | `make demo4-before` and `make demo4-after` still run; read `artifacts/demo4/offcpu-summary.md` for the capture |
| A live capture fails entirely | the matching directory in `artifacts/` |
| Something is on your ports | `make status`, then `make clean` |

Every demo has a terminal-only path. Nothing requires a browser.

## Verify the repository

```bash
make fmt-check     # gofmt
make vet           # go vet
make test          # every test, with -race
make bench         # every benchmark
make shellcheck    # every shell script parses, plus 21 off-CPU report tests
make rehearse      # all of the above, plus every demo end to end
```

The tests are not decoration. Each demo's `broken` and `fixed` implementations are
asserted to produce **identical results**, so "faster" can never quietly mean
"does less work" — and that assertion has already caught one real bug in demo 3,
where a checksum depended on machine speed.

Where a claim can be stated without reference to the clock, it is: demo 2 asserts
the goroutine count grows and stays, demo 3 asserts `peak_working` is 1 versus 16, and demo
4 asserts that 40 concurrent callers produce 40 simultaneous blocked calls in
broken mode and at most 8 in fixed mode. Those pass on a loaded CI box where a
latency threshold would flake.

## Credits

The eBPF off-CPU approach follows Brendan Gregg's
[off-CPU analysis](https://www.brendangregg.com/offcpuanalysis.html) and uses
[BCC](https://github.com/iovisor/bcc), [bpftrace](https://bpftrace.org/) and
[FlameGraph](https://github.com/brendangregg/FlameGraph).
