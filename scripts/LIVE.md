# Live demo scripts

The scripts that run on stage. Same commands as the casts in `casts/`, but the
speaker sets the pace and the trace is read in a real Jaeger UI instead of a
recording — so the audience can be asked to point at a span, and the answer can
be found by clicking rather than by scrubbing a video.

| Script | What happens | Ends on |
| --- | --- | --- |
| `live-demo1-1-load.sh` | starts Jaeger and the four services (`make before`), sends one `curl -sv -o /dev/null /dashboard` | Jaeger opens on the frontend's slowest traces |
| `live-demo1-2-fix.sh` | shows the `Sequential` → `Concurrent` diff, restarts the frontend (`make after`), sends the same request | Jaeger opens on the new traces |
| `live-demo2-1-metric.sh` | starts the server `--metrics-only`, reads `go_goroutines` idle, sends 100 requests, reads it twice more | the gauge still where the traffic left it, nothing in flight |
| `live-demo2-2-pprof.sh` | shows the `diagnosticsMetrics` → `diagnosticsProfiling` diff, restarts with pprof, sends the same 100, lists every goroutine's state before opening one stack | a hundred `[chan send]` headers, then `server.go:176` |
| `live-demo2-3-fix.sh` | shows the `handleWorkBroken` → `handleWorkFixed` diff, restarts fixed, sends the same 100 | the gauge back at baseline, `0` blocked |
| `live-demo3-1-metrics.sh` | part 1: one request, sustained load, `/metrics` three ways, then a CPU profile | ~120 workers, 11 cores available, ~1 core used |
| `live-demo3-2-trace.sh` | part 2: the mutex profile, then the trace's blocking and scheduler profiles, then the timeline | `sync.(*Mutex).Lock` under `computeUnderLock` |
| `live-demo3-3-fix.sh` | part 3: the `computeUnderLock` → `computeThenStore` diff, restarts unlocked, repeats part 1's commands | the same numbers, without the contention |
| `live-demo4-1-request.sh` | act 1: one `curl`, timed | seconds of latency, and nothing on screen saying why |
| `live-demo4-2-pprof.sh` | act 2: load backgrounded, a 10 s `pprof/profile`, then `pprof -top` | `Duration: 10.9s, Total samples = 2.35s (21.5%)` — the rest is unaccounted |
| `live-demo4-3-ebpf.sh` | act 3: load backgrounded, `offcputime-bpfcc` over 10 s to a file, then `flamegraph.pl` | `sha256` → `schedule` with no syscall: preempted, not blocked |
| `live-demo4-4-cgroup.sh` | act 4: `cpu.stat`, `cpu.max`, one request, `cpu.stat` again, then `docker update --cpus=2` and repeat | `nr_throttled` climbing, and ~8 s → ~0.6 s on the same container |

The two states are `make before` and `make after` — the vocabulary the audience is
comparing. Demo 3's modes are `locked` and `unlocked`, named for where the mutex
is; demos 1 and 2 still record `broken|fixed`.

Neither script builds `bin/loadgen`. `before` and `after` compile the frontend and
the dependency binary only: these scripts send one request each, and a
`go build -o bin/loadgen` line on screen invites a question about load that never
comes. `make load` still builds it on demand.

```bash
make demo1-live         # or: ./scripts/live.sh 1-1-load
make demo1-live-fix     # or: ./scripts/live.sh 1-2-fix

make -C demo-01-otel-sequential-calls down     # when you are done
```

Run `1-load`, let the audience read the waterfall and diagnose it out loud, then
run `1-fix`. Neither script names the cause before the trace does: the line
`stage.sh` prints about the three calls being made one after another is filtered
out, and so is its counterpart in the second state. The narration is command
titles only.

## Demo 2 — three acts

```bash
make demo2-live           # or: ./scripts/live.sh 2-1-metric
make demo2-live-pprof     # or: ./scripts/live.sh 2-2-pprof
make demo2-live-fix       # or: ./scripts/live.sh 2-3-fix

make -C demo-02-goroutine-leak down            # when you are done
```

Three rather than two, because the middle act is instrumentation being *added*.
Act 1 has no profiler at all — the server is started `--metrics-only`, which is the
position most services are in — and it ends on the gauge read a third time, with no
traffic in flight and the number unchanged. Act 2 shows the one `mux.Handle` line
that makes a profile possible, restarts, lists every goroutine with its state, and
only then opens one of them down to a function and a line. Act 3 shows the fix the
profile pointed at.

The gauge is scraped with `grep go_goroutines`, not an `awk` that isolates the
value, so `# HELP` and `# TYPE go_goroutines gauge` are on screen every time. The
metric documents itself: a gauge is a snapshot, so a number that rose when work
arrived should fall when the work is over. Act 1 reads it a third time and it does
not.

No command in acts 1 or 2 contains the word `broken`, and `serve.sh` does not report
which mode it started. `--metrics-only` is honest about what is missing without
naming what is wrong.

`make before` and `make after` are the same demo without the pauses: one command
per state, everything printed at once. Right for a rehearsal, wrong for a room —
the audience never sees the reach for the second tool, which is the whole point.

Nothing on screen names the cause. Every narration line is the title of the
command it precedes, so the reading is the speaker's to do out loud — including
the 20 ms timeout against the 90 ms handler, which is worth saying once the
`[chan send]` stack is up. That is also the moment to stop and let the room
propose the fix before you run act 3.

Each act reads the gauge with one `curl | grep` and the profile with two `curl`
commands, and all of them live in
[`demo2-common.sh`](demo2-common.sh) so the numbers on screen in act 3 answer
exactly the question act 2 asked. The acts leave the server running; the next one
restarts it in the shape it needs.

## Demo 3 — three parts

```bash
make demo3-prometheus     # once, if you want the graph as well as the terminal
make demo3-live           # or: ./scripts/live.sh 3-1-metrics
make demo3-live-trace     # or: ./scripts/live.sh 3-2-trace
make demo3-live-fix       # or: ./scripts/live.sh 3-3-fix

make -C demo-03-lock-contention workload-stop down   # when you are done
```

Part 1 is metrics and pprof. A hundred-odd workers alive, eleven cores available,
the process consuming about one core's worth of CPU, and a CPU profile that names
`fnv.Write` at 95 % — correct, and useless. It ends on the distinction the demo
exists to make:

> Metrics tell us that the application is not using the available CPU capacity.
> The mutex profile or Go execution trace tells us why.

Part 2 asks a different question. The mutex profile names `computeUnderLock`. The
trace's blocking profile attributes the wait to `acquire`, and `make sched` shows
the inversion worth stopping on: scheduler latency is microseconds in the locked
mode and minutes in the unlocked one, because blocked and runnable are not the same
state. It ends by opening the timeline: one busy `PROC` row, the rest empty.

Part 3 shows the three-line diff and then repeats part 1's commands against the
same load, with nothing else changed — same 8 concurrent requests, same 16 items,
same 100 ms, same `GOMAXPROCS`. The checksums are identical, which is what makes
this a demo about observability rather than about optimisation.

Part 1 never says the word "mutex". It has to be sayable about a process nobody has
read the source of.

The commands live in [`demo3-common.sh`](demo3-common.sh) so parts 1 and 3 type the
identical thing. Two of them are small scripts rather than one-liners —
`demo-03-lock-contention/scripts/cores.sh` and `waitrate.sh` — because a counter
read once says nothing. Each takes two scrapes a second apart and differences them,
which is the arithmetic behind `rate(process_cpu_seconds_total[30s])`, done in the
terminal so the number is on screen before any browser is.

Part 1 leaves the load running. Part 3 stops it on screen before its single request,
because that request has to be measured on an idle service to be comparable with
part 1's. Capture targets called in between (`make profile-mutex`, `make sync`)
borrow whatever load is already running instead of starting and killing their own.

Prometheus is optional. `make demo3-prometheus` starts one container scraping
`:6062` every second, but every number the parts need is read in the terminal.
There is no Grafana.

`make demo3-before` and `make demo3-after` are the same demo without the pauses:
one command per state, 45 seconds of load each, the queries printed at the end.
Right for a rehearsal or for validating a venue machine, wrong for a room.

## Demo 4 — four acts

```bash
make demo4-live-request   # or: ./scripts/live.sh 4-1-request
make demo4-live-pprof     # or: ./scripts/live.sh 4-2-pprof
make demo4-live-ebpf      # or: ./scripts/live.sh 4-3-ebpf
make demo4-live-cgroup    # or: ./scripts/live.sh 4-4-cgroup

docker compose --profile baseline --profile corrected down   # when you are done
                                                             # (act 3 prints this line)
```

Every command is typed for real — `docker compose up`, `curl`, `go tool pprof`,
`offcputime-bpfcc`, `cat` — the same as demo 2 typing `curl … | grep
go_goroutines`. No `make` targets on screen. That matters more here than elsewhere:
the finding is that after an eBPF program and a flame graph, the thing which names
the cause is a *file*, and `docker exec … cat /sys/fs/cgroup/cpu.stat` says so by
itself where `make cgroup` would hide it.

Two short scripts are the exception, for the reason demo 3 has `cores.sh`:
`load.sh` is a loop that must run in the background, and `offcpu.sh` is awk over
folded stacks. Both are readable, and both are what a viewer reruns at home.

Act 1 is the complaint: an endpoint that does 16 jobs of bounded arithmetic,
taking seconds. `go test -bench=ComputeJob` establishes what that arithmetic costs
— ~70 ms of CPU per job, ~1.2 core-seconds in total — outside any container, so the
room can do the division and find that it does not come out.

**Nothing in acts 1 and 2 names the CPU quota.** Not the value, not the word
"throttle", not a `docker inspect`. The quota is the answer; a run that opens with
`25 ms / 100 ms period (0.25 cores)` has been solved before the first tool comes
out, and the two profiles become a formality. This is the same rule as demo 1's
filtered startup line and demo 2's `--metrics-only`.

That rule is why the mode is called **`baseline`**, not `throttled` — the compose
service key, the profile, the container name and the `-label` the service echoes as
`"mode"`. All four are typed or printed on stage, starting with `docker compose
--profile baseline up -d --wait` as act 1's first command. Naming any of them
`throttled` would answer the demo before a tool was used, and the rename is what
makes typing the real commands possible at all.

Act 2 backgrounds the load and the pprof capture, then runs `offcputime` in the
foreground alongside them, so both profiles cover the same 10 s of the same work —
typed one after the other they would describe two different moments, and the room
would be right to object. The CPU profile is accurate and accounts for a fraction
of the elapsed time; the off-CPU stacks are grouped by *how* the request path left
the CPU, and the group that matters reaches `schedule()` through an interrupt with
no syscall in the stack. It ends on a hypothesis, deliberately:

> The process was runnable and not running: something took the CPU away.
> Nothing so far proves that, and a flame graph on its own cannot.

Act 3 is two `cat`s. `cpu.max` first — two numbers, so the counters underneath mean
something rather than being a wall of integers — then `cpu.stat` read either side
of one request, because the file is cumulative since the container started and a
single read carries every idle period since boot. An idle process cannot be
throttled, so those periods would drag the ratio down for a reason unrelated to the
bug. Read, request, read again: the delta is ~70 periods and ~70 throttled, and the
audience does the subtraction.

Then the two `cpus:` lines from `docker-compose.yml`, `down && up` on the corrected
profile (both services publish :8083, so exactly one can run), the identical
request, and the same two files again — where the delta is 5 periods and **zero**
throttled.

Acts 1 and 3 need Docker; the subject is a cgroup. Act 2 also needs Linux and
root: it loads an eBPF program with BCC's `offcputime`, and BCC compiles against
kernel headers that Docker Desktop's linuxkit VM does not ship. On a non-Linux
host it says so and prints the committed capture from `../artifacts/demo4/`
instead of pretending; the demo 4 README has the Lima VM recipe.

`make demo4-before`, `demo4-investigate` and `demo4-after` compose the same
commands and add the narration a rehearsal wants — right for validating a venue
machine, wrong for a room. `make demo4-full` runs all three unattended.

## How it is paced

Every step prints a short title for the next command and then waits for Enter. A
question from the room costs nothing, and the terminal never runs ahead of the
speaker. Ctrl-C is the way out; `1-load` leaves the services running
so `1-fix` can continue from where it stopped, and the same is true of demo 2's acts
and demos 3 and 4's parts.

No script opens a browser. Where a URL is worth visiting, it is printed as a
clickable link and the speaker decides when to switch — a window appearing by
itself takes the screen away mid-sentence, picks its own display, and may restore
a stale tab. Demo 1 prints the Jaeger search, demo 3 prints `/metrics` in act 1
and the `go tool trace` timeline in act 2, and demo 4 prints the off-CPU flame
graph as a `file://` URL — an SVG on disk, not a server. Every one of them is an
extra over evidence the terminal has already printed; demo 2 needs no browser at
all, because `curl` reads everything it looks at.

## Relationship to the casts

`scripts/live-lib.sh` sources `scripts/cast-lib.sh` with its pacing switched off,
so the two share the parts that must not drift: the colours, the reverse-video
highlighting, and `codediff`, which extracts both versions of a function from the
source file at run time — `internal/dashboard/dashboard.go` for demo 1,
`server.go` for demo 2, `internal/work/work.go` for demo 3. The code on screen is therefore the code that just ran,
live or recorded.

If the projector will not show a browser, `casts/demo1.cast` is the self-contained
fallback: it prints the waterfall in the terminal.
