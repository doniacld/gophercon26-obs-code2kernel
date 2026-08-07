# Demo 3 — lock contention: the mutex profile says where, the trace says why

|                   |                                                                                                                                                                              |
|-------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Symptom**       | `GET /compute` takes 1.6 s to run 16 independent 100 ms tasks on an 11-processor machine. Under 8 concurrent requests it takes 12.8 s.                                       |
| **Main evidence** | The mutex profile, then the execution trace.                                                                                                                                 |
| **Root cause**    | One `sync.Mutex` held across `expensiveWork` as well as `storeResult`.                                                                                                       |
| **Fix**           | Compute first, lock only to store. Three lines move; nothing is deleted.                                                                                                     |
| **Main lesson**   | **Concurrency does not guarantee parallelism.** A large critical section can keep many goroutines active while only one CPU core performs useful work. |
| **Tools**         | Metrics show that the CPU is not being used; the mutex profile and the execution trace show why. |

The code launches 16 goroutines per request. It is concurrent by any reading of
the source. It runs perfectly serially, and it will keep running serially on a
machine with 128 cores.

Measured on this laptop (Apple M3 Pro, Go 1.26.4, `GOMAXPROCS=11`):

|                                              |      locked |      unlocked |           change |
|----------------------------------------------|------------:|-----------:|-----------------:|
| one request, wall clock                      |   1601.6 ms |   102.6 ms | **15.6× faster** |
| `speedup` (CPU time / wall)                  |        1.00 |      15.59 |                  |
| `peak_working` (tasks computing at once)     |       **1** |     **16** |                  |
| lock wait, one request                       | 12,010.2 ms |   0.001 ms |                  |
| `critical_pct`                               |       88.24 |       0.00 |                  |
| 8 requests at concurrency 8                  |    12.812 s |     907 ms |   **14× faster** |
| p95 latency under that load                  | 12,711.9 ms |   842.1 ms |                  |
| throughput                                   |   0.6 req/s |  8.8 req/s |                  |
| total lock wait across the run               |  813,365 ms |       0 ms |                  |
| mutex profile: contention delay              |    948.04 s |   10.22 ms |                  |
| `sync.(*Mutex).Lock` block time (25 s trace) |   1576.39 s | **absent** |                  |
| checksums                                    |   identical |  identical |                  |

The last row is the one that makes this a demo about observability rather than
about optimisation. Both modes compute the same answers, write the same 128
values into the same 16 keys, and pass the same tests under `-race`. Reading the
source will not tell you which one uses the machine.

---

## The bug, in full

```go
// locked                         // unlocked
mu.Lock()                         result := expensiveWork(input)
result := expensiveWork(input)    mu.Lock()
storeResult(result)               storeResult(result)
mu.Unlock()                       mu.Unlock()
```

That is the entire diff. The mutex is not removed, and it must not be: `latest`
is a shared `map[int]Result` that concurrent requests really do write to, and
deleting the lock would trade a throughput bug for a data race. `go test -race`
is in the test suite specifically so that a "fix" of that kind fails loudly.

What changes is the *duration* of the critical section: from 100 ms of hashing
down to one map assignment. The lock protects the map, and it should be held for
exactly as long as the map is being touched.

This shape is common in real code, and it is always *correct* — a cache mutex
held across the computation that produces the value, a metrics mutex held across
a serialization, a "just to be safe" lock around a whole method. There is no
wrong output to find, which is why it survives code review.

## Layout

| Component    | Port | Endpoints                                                                |
|--------------|------|--------------------------------------------------------------------------|
| compute      | 8082 | `GET /compute` (= `POST /process`), `GET /stats`, `GET /reset`, `GET /healthz` |
| diagnostics  | 6062 | `/metrics`, `/debug/pprof/*` (mutex, block, trace, profile), `/debug/flightrecorder` |
| Prometheus   | 9090 | started by `make prometheus`, scrapes :6062 every second                 |
| trace viewer | 9091 | opened by `make view`                                                    |
| pprof web UI | 9092 | opened by `make mutex-web`                                               |

```
cmd/compute        the HTTP service; -mode selects the lock placement
internal/metrics   five demo3_* metrics plus the standard Go and process
                   collectors, on a registry of their own
cmd/loadgen        deterministic load: unlocked request count, unlocked concurrency,
                   no randomness anywhere
internal/work      Store, RunLocked, RunUnlocked — and one shared run() so the two
                   modes provably differ only in lock placement
```

`RunLocked` and `RunUnlocked` both delegate to the same `run()` with a single
`lockFirst bool`. The goroutine structure, the timing, the bookkeeping and the
cancellation handling are therefore identical by construction, not by careful
copy-paste. That is what licenses the claim that the difference is three lines.

## Run it

```bash
make prometheus       # a scraper, once
make before           # locked under sustained load  -> ~1 core of 11 used
make after            # unlocked, identical load        -> ~8.5 cores used

make locked           # the mutex is held across expensiveWork
make one              # 1.6s, speedup 1.00, peak_working 1
make profile-mutex    # FIRST REVEAL
make trace && make view   # SECOND REVEAL

make unlocked            # the mutex covers storeResult only
make one              # 0.1s, speedup 15.6, peak_working 16
make profile-mutex    # contention is gone
make trace && make view
```

From the repository root: `make demo3-locked`, `make demo3-unlocked`,
`make demo3-load`, `make demo3-profile-mutex`, `make demo3-trace`.

### On stage

Three speaker-paced acts, one Enter per command:

```bash
make demo3-prometheus     # once, optional — the graph as well as the terminal
make demo3-live           # act 1: many workers, many cores, ~1 core used
make demo3-live-trace     # act 2: the CPU profile fails; the mutex profile does not
make demo3-live-fix       # act 3: the fix, the same load, the same questions
```

Act 1 stops where metrics stop. Act 2 is the reach for the second tool, and it
starts with a CPU profile that is correct and useless. Act 3 changes three lines and
runs every earlier command again. Details, and what each act deliberately does not
say, are in [`scripts/LIVE.md`](../scripts/LIVE.md).

### Exact commands

Everything the Makefile does, spelled out. Nothing here needs the Makefile.

```bash
go build -o bin/compute ./cmd/compute
go build -o bin/loadgen ./cmd/loadgen

./bin/compute -addr :8082 -diag-addr :6062 -mode locked \
  -work-items 16 -work-duration 100ms \
  -max-items 512 -max-duration 1s \
  -mutex-profile-fraction 1 -block-profile-rate 10000 &

# readiness, not sleep — both ports, because both are load-bearing
until curl -fsS http://localhost:8082/healthz    >/dev/null; do sleep 0.1; done
until curl -fsS http://localhost:6062/debug/pprof/ >/dev/null; do sleep 0.1; done

curl -s "http://localhost:8082/compute" | python3 -m json.tool
./bin/loadgen -url http://localhost:8082/compute \
  -requests 8 -concurrency 8 -items 16 -duration 100ms
```

Per-request overrides, no restart needed:

```bash
curl -s "http://localhost:8082/compute?items=32&duration=50ms"
curl -s "http://localhost:8082/compute?mode=unlocked"    # both modes, one process
```

Out-of-range values are **rejected, not clamped**:

```
$ curl -s "http://localhost:8082/compute?items=99999"
items=99999 exceeds max-items=512
$ curl -s "http://localhost:8082/compute?duration=30s"
duration=30s exceeds max-duration=1s
$ curl -s "http://localhost:8082/compute?mode=nope"
mode=nope: want locked or unlocked
```

Silently serving 512 items when the URL said 99,999 would make the demo lie
about what it just did.

### Capturing the two reveals

```bash
# 1. the mutex profile — a snapshot of accumulated contention, taken under load
curl -o mutex.pb.gz http://localhost:6062/debug/pprof/mutex
go tool pprof -top mutex.pb.gz

# 2. the execution trace — a recording of a window of time
curl -o trace.out "http://localhost:6062/debug/pprof/trace?seconds=8"
go tool trace -http=:9091 trace.out

# the trace's own blocking profile, no browser required
go tool trace -pprof=sync  trace.out > sync.pprof
go tool trace -pprof=sched trace.out > sched.pprof
go tool pprof -top sync.pprof
```

| Target               | What it does                                                               |
|----------------------|----------------------------------------------------------------------------|
| `make one`           | one request, formatted — the diagnosis in eight lines of JSON              |
| `make load`          | `REQUESTS` requests at `CONCURRENCY`, then `/stats`                        |
| `make profile-mutex` | **first reveal**: contention under load → `artifacts/demo3-mutex-profile/` |
| `make mutex-web`     | the same profile in the pprof web UI, with annotated source                |
| `make trace`         | **second reveal**: `TRACE_SECONDS` of execution trace under load           |
| `make view`          | open that trace in `go tool trace` on `:9091`                              |
| `make sync`          | blocking profile derived from the trace — no browser needed                |
| `make sched`         | scheduler-latency profile: runnable-but-not-running time                   |
| `make profile-block` | the block profile: all blocking, not just mutexes                          |
| `make profile-cpu`   | a CPU profile, to show what it *cannot* tell you                           |
| `make compare`       | both modes, one request each, side by side                                 |
| `make capture`       | both reveals plus committable text summaries                               |

Every capture target starts the load generator first, waits `RAMP` seconds, and
stops it afterwards. A mutex profile of an idle process is empty and a trace of
one is a blank timeline; making that impossible to forget is worth a few lines of
Makefile.

Captures are labelled with the mode the service is **actually running in**, read
back from `.run/mode`, not from `MODE`. `make unlocked` followed by `make trace`
runs a second `make` process where `MODE` has reverted to its default; labelling
by `MODE` would write the unlocked build's trace into `demo3-locked-trace/`. On
stage that means showing a "before" file recorded after the fix — worse than
having no file at all.

## Expected output

### Locked

```
$ make one
{
    "checksum_head": [1852204774866425125, 5387141787440594725, 11421846288246327781],
    "cpu_time_ms": 1600,
    "critical_pct": 88.24,
    "gomaxprocs": 11,
    "items": 16,
    "lock_wait_ms": 12010.169,
    "mode": "locked",
    "parallelism": "serial: 11 processors available, 1 task at a time",
    "peak_working": 1,
    "speedup": 1,
    "task_ms": 100,
    "wall_ms": 1601.628
}
```

Three numbers, no profiler:

- **`speedup: 1`** is `cpu_time_ms / wall_ms`. 1.00 means the tasks ran one after
  another. Two timestamps the handler already had.
- **`peak_working: 1`** is how many tasks were ever inside `expensiveWork` at the
  same time. This is the bug stated without reference to the clock — it is 1 on
  a fast machine and 1 on a slow one, and no timing measurement is that robust.
- **`lock_wait_ms: 12010`** is more than the request took. Sixteen goroutines
  each waited for the ones ahead of them; summed, that is 12 s of waiting inside
  a 1.6 s request. Contention is denominated in goroutine-seconds.

The cheapest observability in this entire talk is a ratio you can compute in
five lines of application code. Reach for it before you reach for a profiler.

```
$ make load
loadgen: GET http://localhost:8082/compute?duration=100ms&items=16 requests=8 concurrency=8
requests=8 concurrency=8 ok=8 errors=0 wall=12.812s
  latency  min=2203.5ms avg=8858.9ms p50=7908.0ms p95=12711.9ms p99=12711.9ms max=12812.0ms
  throughput 0.6 req/s
  status 200=8
  peak concurrent tasks 1 of 11 processors   goroutines 7
  lock wait  total 813365ms   avg per task 6354.4ms
  store      128 writes across 16 keys   requests 8
```

Note the latency spread: `min` 2.2 s, `max` 12.8 s. Eight requests arrive
together, and the last one to get the lock waits for all 128 tasks ahead of it.
This is a queue, and the tell of a queue is that latency depends on arrival
order rather than on the work requested. Every request asked for exactly 16 × 100
ms of work.

`goroutines 7` is worth pointing at: this is *not* a goroutine leak. Only 7
goroutines exist when the run ends. The problem is not how many goroutines there
are, it is that 127 of the 128 that existed a moment ago were parked on a lock.

### Unlocked

```
$ make one
{
    "checksum_head": [1852204774866425125, 5387141787440594725, 11421846288246327781],
    "cpu_time_ms": 1600,
    "critical_pct": 0,
    "gomaxprocs": 11,
    "items": 16,
    "lock_wait_ms": 0.001,
    "mode": "unlocked",
    "parallelism": "parallel: 16 tasks at once, 11 processors, 15.6x the serial rate",
    "peak_working": 16,
    "speedup": 15.59,
    "task_ms": 100,
    "wall_ms": 102.623
}
```

`checksum_head` is byte-identical to locked mode. Same inputs, same outputs,
same shared map — 15.6× the throughput.

```
$ make load
requests=8 concurrency=8 ok=8 errors=0 wall=907ms
  latency  min=193.7ms  avg=587.6ms  p50=553.5ms  p95=842.1ms  p99=842.1ms  max=906.6ms
  throughput 8.8 req/s
  status 200=8
  peak concurrent tasks 33 of 11 processors   goroutines 7
  lock wait  total 0ms   avg per task 0.0ms
  store      128 writes across 16 keys   requests 8
```

**A speedup of 15.59 on 11 processors, and 33 tasks at once.** Both look
impossible and both are honest, for the same reason: `expensiveWork` burns CPU
until a wall-clock deadline, so when 128 tasks share 11 processors each one
completes rather less than its nominal 100 ms of hashing. `cpu_time_ms` is the
*requested* 1600 ms, which becomes an overestimate under oversubscription, and
the derived speedup inherits that. It is a property of the workload's deadline,
not a measurement error.

When the two disagree, trust `peak_working`. It counts goroutines, not
nanoseconds. `1` versus `16` is the fact; `1.00` versus `15.59` is the
consequence.

## Zeroth reveal — metrics, from outside the process

Before any profiler: a Prometheus scrape of the running service, and two lines on
one graph.

```bash
make prometheus       # one container, scraping :6062 every second
make before           # locked mode, 45 s of sustained load, then the queries
make after            # unlocked mode, identical load
```

`make before` and `make after` are sequential, not side by side — both bind
:8082 and :6062, so Prometheus follows one target that changes underneath it. Run
`before`, read the graph, then `after` and read the same graph again. Every metric
carries `mode="locked"` or `mode="unlocked"` so a range long enough to span both
still separates them.

Nothing changes between the two but the lock placement: same 8 concurrent
requests, same 16 items, same 100 ms per item, same `GOMAXPROCS`.

### The queries

```promql
rate(process_cpu_seconds_total[30s])
```

CPU cores the process is consuming. This is the number the demo turns on.

```promql
go_sched_gomaxprocs_threads
```

Cores it is allowed to use.

```promql
100 * rate(process_cpu_seconds_total[30s]) / go_sched_gomaxprocs_threads
```

Share of the process's own CPU allowance. Note what this is *not*: 100 % here
means the process is using every core it was given, not that the machine is
saturated — a 1-core process on a 64-core box reads 100 % while 63 cores idle.

```promql
demo3_active_workers
rate(demo3_mutex_wait_seconds_total[30s])
histogram_quantile(0.95, sum by (le) (rate(demo3_request_duration_seconds_bucket[30s])))
rate(demo3_items_processed_total[30s])
```

Workers alive right now; seconds of waiting accumulated per second, which reads as
a count of goroutines doing nothing; p95 batch latency; throughput in items per
second.

`make queries` prints all of them, and `make metrics` shows the raw scrape if a
browser is not available.

### What it looks like

Measured on this laptop (Apple M3 Pro, 11 CPUs, `GOMAXPROCS=11`, Go 1.26.4),
during `make before` and `make after` at 8 concurrent requests of 16 × 100 ms:

|                                                  |    locked |     unlocked |
|--------------------------------------------------|----------:|----------:|
| `rate(process_cpu_seconds_total[30s])`            | 0.99 cores | 8.57 cores |
| `go_sched_gomaxprocs_threads`                     |        11 |        11 |
| share of its own CPU allowance                    |     9.0 % |    77.9 % |
| `demo3_active_workers`                            |       121 |        31 |
| `rate(demo3_mutex_wait_seconds_total[30s])`       | 119.7 s/s |  0.0006 s/s |
| p95 batch latency                                 |    20.0 s |    0.88 s |
| `rate(demo3_items_processed_total[30s])`          |  9.9 items/s | 222.9 items/s |
| `go_goroutines`                                   |       147 |       114 |

Read the first four rows together, because that is the whole slide:

> **16 workers per request, 11 cores available, about 1 core used.**

The locked row is the shape worth recognising. A hundred-odd workers are alive,
eleven cores are available and idle, and the process consumes one core's worth of
CPU — and it accumulates 120 seconds of waiting every second, which is another way
of saying that around 120 goroutines are sitting still at any moment.

The unlocked row is the same load doing 22× the work at 1/23rd the latency, on nine
times the CPU. `demo3_active_workers` is *lower* in unlocked mode, and that is not a
mistake: workers finish instead of piling up.

### What metrics can and cannot tell you

Metrics tell us that the application is not using the available CPU capacity.
The mutex profile or Go execution trace tells us why.

Prometheus does not prove contention. A process using one core out of eleven could
be blocked on a mutex, blocked on a socket, blocked on a channel, or simply not be
given work. `demo3_mutex_wait_seconds_total` narrows it — the application is
saying, in its own voice, that it is waiting on a lock — but it is an operational
signal, not the diagnosis. It names no line of code, no critical section and no
call stack. The two reveals below are what do that, and this section exists to
make you want them.

## First reveal — the mutex profile

```
$ make profile-mutex                                          # MODE=locked
Type: delay
Showing nodes accounting for 948.04s, 100% of 948.04s total
      flat  flat%   sum%        cum   cum%
   948.04s   100%   100%    948.04s   100%  sync.(*Mutex).Unlock
         0     0%   100%    948.04s   100%  work.(*Store).computeUnderLock
         0     0%   100%    948.04s   100%  work.(*Store).run.func1
```

```
$ make profile-mutex                                          # MODE=unlocked
Type: delay
Showing nodes accounting for 10220.63us, 100% of 10224.50us total
      flat  flat%   sum%        cum   cum%
 8272.77us 80.91% 80.91%  8272.77us 80.91%  runtime.unlock (partial-inline)
 1947.86us 19.05%   100%  1947.86us 19.05%  runtime._LostContendedRuntimeLock
```

948 seconds of contention delay against 10 milliseconds: five orders of
magnitude, one function name, no ambiguity about which line to look at. And in
unlocked mode `sync.(*Mutex).Unlock` is not merely small — it is **absent**. What
remains is `runtime.unlock`, the runtime's own internal locks (scheduler, heap),
which are not yours and are not actionable.

Three things about this profile catch people out, in rough order of how often:

**It is off by default.** `runtime.SetMutexProfileFraction(N)` must be called or
the profile comes back empty. This is the single most common reason a mutex
profile shows nothing: the runtime was never asked to collect it. The service
does it at startup and logs the value:

```
level=INFO msg="demo 3 compute ready" mode=locked mutex_profile_fraction=1 GOMAXPROCS=11
```

The fraction is a 1-in-N sampling rate for contention *events*. `1` records all
of them, which is what a demo wants; the runtime does bookkeeping on every
contended unlock, so a busy service with a hot lock pays for that. ~100 is a
reasonable production value.

**The units are contention delay, summed across goroutines — not elapsed time.**
948 s inside a 25 s window is not a bug in the tool. Roughly 128 blocked
goroutines accumulate wall-clock time 128× faster than the clock runs. Expect the
digits to move run to run; the magnitude is the point.

**It blames `Unlock`, not `Lock`.** The runtime charges the delay at the moment
the holder releases the lock and wakes the waiters, because that is where it
learns how long they waited. Read the frames beneath it (`computeUnderLock`) to find
the code, and do not go looking for a slow `Unlock` — there is no such thing.

### What the mutex profile reveals, and what it does not

Reveals:

- Which lock is contended, and which call site holds it.
- How much delay accumulated there in total, so you can rank several locks.
- That the cost is real: 948 s does not appear in a process that is merely busy.
- Whether a fix worked: rerun it and the entry is gone, not smaller.

Does not reveal:

- **When.** A total cannot tell a steady 5 % tax from a five-second stall. Both
  produce the same number.
- **What the blocked goroutines would have done.** The profile knows they waited;
  it does not know 11 processors were idle while they did.
- **Whether contention or lock duration is the problem.** 948 s is consistent
  with "many goroutines, short critical section" and with "few goroutines, very
  long critical section". These have different fixes.
- **Which requests suffered.** There is no request identity in a profile.
- **Uncontended lock cost.** A fast-path `Lock` never appears here, however hot.
- **Latency.** Nothing in this profile is a percentile.

Every one of those gaps is why the demo does not stop here.

> The mutex profile tells us where contention accumulated. The execution trace
> explains how the contention unfolded over time.

## Second reveal — the execution trace

```bash
make trace        # TRACE_SECONDS of trace under load
make view         # go tool trace on :9091
```

`go tool trace` opens an index. Work through these pages in this order.

### 1. `View trace by proc` — the processor timeline

The picture that needs no explanation. In locked mode one `PROC` row carries a
continuous band and the other ten are empty for the whole window. In unlocked mode
all eleven are busy at once.

Point at the ten empty rows: **the CPU was available the entire time and the
program declined to use it.** Nothing else in the toolchain states that as
plainly.

Zoom in (`W` to zoom, `S` out, `A`/`D` to pan) and the locked timeline resolves
into 100 ms blocks laid end to end, each on whichever processor happened to pick
up the goroutine that just won the lock. Work is *moving between* processors
without ever *overlapping* on them.

### 2. `Goroutine analysis` — where the time went, per goroutine

Click the `work.(*Store).run.func1` row: 374 goroutines in the locked window,
`99.88% of total program execution time`. Its Breakdown table is the single best
artifact in this demo.

```
Goroutine |          Total |      Execution |   Block time (sync) |   Sched wait
      808 |  12.933772928s |   100.096064ms |       12.833642752s |     34.112µs
      731 |  12.933111232s |   100.443456ms |       12.832598272s |     69.504µs
      794 |  12.929139328s |    99.889087ms |       12.828967552s |    282.689µs
      745 |  12.927334272s |     100.1232ms |        12.82718496s |     26.112µs
      ... |            ... |            ... |                 ... |          ...
      995 |   275.992065ms |          640ns |       275.977857ms |     13.568µs
      996 |   275.991873ms |        7.424µs |       275.983105ms |      1.344µs
      597 |   181.999424ms |   100.049088ms |                  0s |     14.592µs
      596 |    81.938368ms |    81.934272ms |                  0s |      4.096µs
```

**Execution time is a constant ~100 ms. Total is queue position × 100 ms.** Every
goroutine did exactly the same amount of work; the only thing that varies is how
long it waited its turn. The last two rows are the lucky ones that took the lock
immediately and blocked for nothing.

Read one column pair aloud and the room gets it: *"execution time, one hundred
milliseconds. Block time, twelve point eight seconds."*

Aggregated over all 374 goroutines in that window:

| Share of goroutine lifetime       |     locked |    unlocked |
|-----------------------------------|-----------:|---------:|
| executing                         |  **0.8 %** |   14.7 % |
| blocked on synchronization        | **76.2 %** |    2.3 % |
| runnable, waiting for a processor |  **0.0 %** |   83.0 % |
| median lifetime                   |    9.140 s |  0.316 s |
| median execution time             |   100.0 ms |  48.4 ms |
| median sync block                 |    6.685 s |  **0 s** |
| median sched wait                 | **0.0 ms** | 263.1 ms |

### 3. Runnable versus running — the inversion that explains everything

The `Sched wait time` column above is the subtlest and most valuable thing on
the page, and it is what separates two failure modes that look identical from
the outside.

- **Locked mode: sched wait ≈ 0.** `make sched` reports **7.11 ms** in total.
  Nothing is waiting for a processor, because processors are idle. These
  goroutines are *blocked* — parked on a mutex, not runnable at all, invisible
  to the scheduler.
- **Unlocked mode: sched wait dominates.** `make sched` reports **388.51 s**,
  and 83 % of the average goroutine's life is spent runnable-but-not-running.

That inversion is worth saying twice. The *healthy* program has four orders of
magnitude **more** scheduler latency than the locked one. In unlocked mode
goroutines queue for processors because all eleven are busy — which is what
saturation looks like and is the correct state for a CPU-bound service. In locked
mode nobody queues for a processor because nobody is runnable.

"Blocked" and "runnable but not scheduled" have completely different fixes:
shorten the critical section, versus add cores or admit less work. A CPU profile
shows neither state. The trace distinguishes them by name.

### 4. `Synchronization blocking profile` — the number to read aloud

Available in the browser, or as a pprof file with no browser at all:

```
$ make sync                                                   # MODE=locked
Type: delay
Showing nodes accounting for 1753.65s, 100% of 1753.65s total
      flat  flat%   sum%        cum   cum%
  1576.39s 89.89% 89.89%   1576.39s 89.89%  sync.(*Mutex).Lock
   103.21s  5.89% 95.78%    103.21s  5.89%  sync.(*WaitGroup).Wait
    49.04s  2.80% 98.57%     49.04s  2.80%  runtime.chanrecv1
       25s  1.43%   100%        25s  1.43%  runtime.selectgo
         0     0%   100%   1576.39s 89.89%  work.(*Store).acquire
         0     0%   100%   1576.39s 89.89%  work.(*Store).computeUnderLock
```

```
$ make sync                                                   # MODE=unlocked
Type: delay
Showing nodes accounting for 303.75s, 100% of 303.87s total
      flat  flat%   sum%        cum   cum%
   186.79s 61.47% 61.47%    186.79s 61.47%  sync.(*WaitGroup).Wait
    48.24s 15.87% 77.35%     48.24s 15.87%  runtime.chanrecv1
    43.70s 14.38% 91.73%     43.70s 14.38%  runtime.gcMarkDone
    25.02s  8.23%   100%     25.02s  8.23%  runtime.selectgo
```

`sync.(*Mutex).Lock` at 89.89 %, then gone entirely. What remains in unlocked mode
is *healthy* blocking: `WaitGroup.Wait` is the handler waiting for its own tasks
to finish, which is the whole point of the handler, and `selectgo` is the trace
endpoint sleeping through its own capture window.

This is the strongest evidence in the demo that survives a projector refusing to
render the timeline — it is a plain pprof file.

**One caveat, and it will bite you.** A trace-derived blocking profile counts a
wait only once it has both *started and ended* inside the trace window. At 16
tasks × 100 ms a queued goroutine waits up to 12 s, so an **8-second trace
contains zero completed mutex waits** and `sync.(*Mutex).Lock` disappears from
the profile — making the bug look unlocked. That is why `make sync` captures 25 s
(`SYNC_SECONDS`) rather than the 8 s used for the visual timeline, warns you if
no mutex waits landed in the window, and recaptures automatically. The runtime
mutex profile has no such constraint, which is an independent reason it goes
first.

### 5. `User-defined regions` — the application's own vocabulary

The code annotates itself with `runtime/trace` regions, so the trace speaks in
domain terms rather than in Go internals:

| Region                             |     locked |      unlocked |
|------------------------------------|-----------:|-----------:|
| `compute.locked` / `compute.unlocked` | 8 requests | 8 requests |
| `lock.wait`                        |        256 |       5652 |
| `work.compute`                     |        248 |       5648 |

Two hundred and fifty-six waits against 5,652 in the same wall-clock window:
the unlocked build got through twenty-two times as much work. Open a `lock.wait`
region in locked mode and it spans nearly the entire request; in unlocked mode you
have to zoom in past the microsecond scale to find one.

Three lines of `trace.StartRegion` bought that. It is the cheapest way to make a
trace legible to someone who did not write the code.

### 6. Before and after, in one glance

| Page | locked | unlocked |
| --- | --- | --- |
| **View trace by proc** | 1 row busy, 10 idle | 11 rows busy |
| **Goroutine analysis** | execution 0.8 % of lifetime | execution 14.7 % |
| **Breakdown table** | 100 ms staircase in `Block time (sync)` | sync column empty for the median goroutine |
| **Synchronization blocking** | `sync.(*Mutex).Lock` 1576 s (89.89 %) | absent; `WaitGroup.Wait` on top |
| **Scheduler latency** | 7.11 ms — nothing waits for a core | 388.51 s — everything does |
| **Network blocking profile** | negligible | negligible — this is not I/O (see demo 4) |
| **Syscall profile** | negligible | negligible |
| **User-defined regions** | 256 `lock.wait` | 5652 `lock.wait` |

### What the execution trace reveals, and what it does not

Reveals:

- **When**, not just how much. Every event carries a timestamp.
- Which goroutine ran on which processor, and what it was doing in between.
- The difference between *blocked*, *runnable*, and *running*.
- Per-goroutine latency, so you can see a queue as a queue.
- GC, syscalls, network waits and your own regions on one shared time axis.

Does not reveal:

- **Line-level CPU cost.** Use a CPU profile for that; they are complements.
- **Anything outside the window.** A trace is a recording, not a total —
  including waits that straddle its edges.
- **Anything about a process you did not think to trace.** The flight recorder
  (`/debug/flightrecorder`) exists for this: a rolling in-memory window you can
  snapshot *after* something interesting happens.
- Long windows cheaply: 25 s of this workload is 370 KB locked and 850 KB unlocked
  — the busier the program, the bigger the file.
- A readable picture at high concurrency. The timeline is legible at
  `CONCURRENCY=1` and a wall of blocks at 64.

## Why a CPU profile does not find this

Try it first on stage, and let it fail. `make profile-cpu` in each mode:

```
locked                                        unlocked
Duration: 8.20s, samples = 7.23s (88.20%)     Duration: 8.17s, samples = 56.38s (690.48%)
  6.88s 95.16%  hash/fnv.(*sum64a).Write        50.99s 90.44%  hash/fnv.(*sum64a).Write
  0.18s  2.49%  runtime.asyncPreempt             4.00s  7.09%  runtime.asyncPreempt
  7.14s 98.76%  (*Store).expensiveWork [cum]    56.22s 99.72%  (*Store).expensiveWork [cum]
```

Same function, same rank, same ~90 % share, same shape — before and after. A CPU
profile answers *"which code burned the cycles"*, and the answer, `fnv.Write`, is
correct, unchanged by the fix, and useless. The bug is not in `fnv.Write`. The
bug is in the **overlap** of the goroutines calling it, and a CPU profile has no
notion of overlap: it is a bag of stack samples with the time axis discarded.

Two things it structurally cannot represent, both essential here:

- **Which goroutine ran when.** Samples are aggregated across goroutines. Sixteen
  goroutines running 100 ms each in sequence and sixteen running 100 ms each
  simultaneously produce the same stacks in the same proportions.
- **Time spent not running.** A blocked goroutine is off-CPU and contributes no
  samples at all. The 12.8 s a goroutine spends waiting for the mutex is not
  small in this profile — it is *absent*.

There is one exception, and it is the most useful line in the whole demo:

```
Duration: 8.20s, Total samples =  7.23s  (88.20%)   <-- locked
Duration: 8.17s, Total samples = 56.38s (690.48%)   <-- unlocked
```

That percentage is samples over wall clock — effectively **average processors in
use**. 88 % is less than one. 690 % is seven. The CPU profile did contain the
answer, in the header line everyone scrolls past.

This is not a failure of pprof. It is a tool answering the question it was built
for. Ask "where did the cycles go" and you get `fnv.Write`, in both modes,
forever.

## Correctness

```bash
make test     # go test -race ./...
make bench
```

```
BenchmarkLocked-11    10   32895154 ns/op
BenchmarkUnlocked-11     10    4202692 ns/op      7.8x
```

| Test | Asserts |
| ---- | ------- |
| `TestLockedModeSerializesTheWork` | `PeakWorking == 1` **exactly** — the bug with no reference to the clock, so it cannot flake on slow CI |
| `TestUnlockedModeUsesTheCores` | more than one task computes at once |
| `TestUnlockedModeBeatsLocked` | on `LockWait`, not only on wall clock |
| `TestBothModesProduceTheSameChecksums` | the fix computes the same answers |
| `TestChecksumsAreDistinctPerTask` | the workload is not accidentally constant |
| `TestChecksumIsIndependentOfDuration` | a faster machine gets the same answer |
| `TestStoreHoldsTheLatestResultPerItem` | 4 concurrent requests mixing both modes over the same keys — **this is what fails if the fix "optimises" the lock away** |
| `TestCancellationIsObserved` | documents the uncancellable-mutex limitation below |
| `TestResetClearsTheCounters` | `/reset` really resets |
| `TestRunRejectsUnknownMode` | bad input is an error, not a default |

`TestUnlockedModeBeatsLocked` logs the comparison, so `go test -v` is a fallback
demo if the network stack misbehaves on stage:

```
work_test.go:85: locked 241ms (speedup 1.00, lock wait 1.806s) vs
                 unlocked   30ms (speedup 7.93, lock wait 0s)
```

Run `make test` on the venue machine before the talk. If the room's hardware
cannot demonstrate the difference, these tests fail and tell you so before the
audience does.

`TestChecksumIsIndependentOfDuration` earned its place during development. The
workload originally accumulated one hash across the whole timed loop, so the
result depended on how many iterations fit in 100 ms and therefore on machine
load — the equivalence test between the two modes was passing by luck. Each
round now resets the hash, so only the *number* of rounds varies with the clock.

### A limitation worth showing: you cannot cancel a mutex wait

`sync.Mutex` has no context-aware `Lock`. A goroutine already queued on a mutex
cannot be cancelled; all `acquire` can do is check `ctx.Err()` *after* it wins
the lock and hand it straight back:

```go
s.mu.Lock()
wait := time.Since(queued)
if err := ctx.Err(); err != nil {
    s.mu.Unlock()
    return wait, false
}
```

So a lock held for 100 ms makes every request behind it uncancellable for up to
100 ms per queued task. Ctrl-C during a locked-mode load run, or watch
`cancelled_batches` climb in `/stats`: the clients are long gone and the tasks
are still working through the queue. **One slow critical section defeats an
entire timeout strategy** — the timeout fires, the client leaves, and the server
keeps paying. Demo 4 is about the other half of that story.

## Speaker flow (4–6 minutes)

0. **Start from the dashboard, if there is a projector for it.** `make prometheus`,
   then `make before`. One line for `rate(process_cpu_seconds_total[30s])`, one for
   `go_sched_gomaxprocs_threads`, one for `demo3_active_workers`. *"A hundred and
   twenty workers. Eleven cores. One core's worth of work getting done."* Say what
   this does and does not establish: the application is not using the CPU it has,
   and nothing here says why.
1. **State the shape.** `make locked`, then `make one`. 16 tasks × 100 ms = 1.6 s
   on an 11-processor machine. *"This launches sixteen goroutines. It is
   concurrent. It is not parallel."*
2. **Show it in the response body.** `speedup: 1.00`, `peak_working: 1`. No
   profiler yet — five lines of application code found this.
3. **Show it under load.** `make load`: 12.8 s, p95 12.7 s, and `min` 2.2 s
   against `max` 12.8 s. *"Same work in every request. Latency depends on
   arrival order. That is a queue."*
4. **Try a CPU profile and let it fail.** `make profile-cpu`. `fnv.Write`, 95 %.
   *"Correct. Useless. It says the same thing after I fix the bug."* Then point
   at `Total samples = 7.23s (88.20%)` — under one processor, in the header
   nobody reads.
5. **First reveal.** `make profile-mutex`: `sync.(*Mutex).Unlock`, 948 s of
   delay. Say the two things that confuse people — it is off by default, and the
   units are goroutine-seconds of delay, not elapsed time. Then: *"This tells me
   which lock. It does not tell me what those goroutines would have been doing."*
6. **Second reveal.** `make trace && make view`. *View trace by proc* — one busy
   row, ten empty. Then *Goroutine analysis* → `run.func1` → the Breakdown
   table, and read one row aloud: execution 100 ms, block 12.8 s.
7. **The browser-free version.** `make sync`: `sync.(*Mutex).Lock`, 1576 s,
   89.89 %.
8. **The fix.** Show the three lines. Stress that the mutex stays — `make test`
   runs under `-race` and the store is genuinely shared. *"The lock protects a
   map. Hold it for as long as you touch the map."*
9. **Same load, unlocked.** `make unlocked && make one` → 102 ms, `peak_working: 16`,
   identical checksums. `make load` → 907 ms, 8.8 req/s.
10. **`make trace && make sync`.** `Mutex.Lock` is gone. Then the inversion:
    `make sched` is 7 ms locked and 388 s unlocked. *"The healthy program has more
    scheduler latency. Blocked and runnable are not the same thing, and only one
    tool here tells them apart."*
11. **The lesson.** *"Concurrency does not guarantee parallelism."*

    Supporting point: *"A large critical section can keep many goroutines active
    while only one CPU core performs useful work."*

    And the division of labour between the tools, if you ran the metrics step:
    *"Metrics tell us that the application is not using the available CPU
    capacity. The mutex profile or Go execution trace tells us why."*

    Profiles aggregate where time accumulates. Execution traces preserve
    scheduling and synchronization over time.

Closing line if you want one: *"A profile is a photograph of where time was
spent. A trace is the film — and this bug only exists in the edit."*

## Configuration

| Flag / variable | Default | Meaning |
| --------------- | ------- | ------- |
| `MODE` / `-mode` | `locked` | `locked` \| `unlocked` |
| `WORK_ITEMS` / `-work-items` | `16` | independent tasks per request |
| `WORK_DURATION` / `-work-duration` | `100ms` | CPU time per task |
| `MAX_ITEMS` / `-max-items` | `512` | hard cap on `?items=`; 1–4096 |
| `-max-duration` | `1s` | hard cap on `?duration=` |
| `MUTEX_FRACTION` / `-mutex-profile-fraction` | `1` | `SetMutexProfileFraction`; `0` disables the profile |
| `-block-profile-rate` | `10000` | `SetBlockProfileRate` in ns |
| `REQUESTS` | `8` | load generator request count |
| `CONCURRENCY` | `8` | load generator workers |
| `TRACE_SECONDS` | `8` | trace window for the visual timeline |
| `SYNC_SECONDS` | `25` | trace window for `make sync` — see the caveat above |
| `RAMP` | `1` | seconds of load before a capture starts |
| `WORKLOAD_SECONDS` | `45` | how long `make before` / `make after` drive load |
| `PROM_PORT` | `9090` | Prometheus UI |
| `PROM_TARGET` | `host.docker.internal:6062` | what Prometheus scrapes; use `localhost:6062` for a Prometheus running on the host |
| `-flight-window` | `5s` | flight recorder history; `0` disables it |

**Why `REQUESTS=8` and not more.** Eight requests at concurrency 8 is exactly one
round: all eight start together and the run ends when the slowest finishes.
Locked mode has to grind through 8 × 16 × 100 ms = 12.8 s of serialized work, so
each extra round adds another 12.8 s. At `REQUESTS=24` that is a 38-second wait
in front of an audience. One round already saturates the lock.

**The machine stays responsive.** Locked mode uses one processor by definition.
Unlocked mode uses all of them for under a second per round. Nothing here runs
unbounded, and `-max-items` × `-max-duration` bounds the worst case a URL can
ask for.

For a bigger room: `make locked WORK_ITEMS=32` → 3.2 s per request. For a
readable timeline: `make trace CONCURRENCY=1` — one request at a time, and the
staircase is visible without zooming.

## Fallback artifacts

`make capture` writes both reveals plus small text summaries that can be
committed:

```
artifacts/demo3-mutex-profile/
  mutex-locked.pb.gz  mutex-unlocked.pb.gz     the profiles themselves
  top-locked.txt      top-unlocked.txt         go tool pprof -top output
  cpu-locked.pb.gz    cpu-unlocked.pb.gz       the deliberately unhelpful contrast
  block-locked.pb.gz  block-unlocked.pb.gz
  stats-locked.json   stats-unlocked.json
artifacts/demo3-locked-trace/
artifacts/demo3-unlocked-trace/
  trace.out          the trace (SYNC_SECONDS long, so make sync works offline)
  sync.pprof         sync-top.txt
  sched.pprof
  one-request.json   the single-request JSON, for reading the numbers aloud
```

The `.pb.gz` and `trace.out` files are machine-specific and gitignored; the
`.txt` and `.json` summaries are small and committed. If the tools will not
cooperate on stage, the numbers are still on disk and `make one` still works
without any profiler.

## Troubleshooting

| Symptom | Cause | Fix |
| ------- | ----- | --- |
| mutex profile is empty | `SetMutexProfileFraction` not called, or `-mutex-profile-fraction 0` | check the startup log for `mutex_profile_fraction=1` |
| mutex profile is empty, fraction is set | captured while idle | use `make profile-mutex`, which loads first; a bare `curl` catches nothing |
| mutex profile shows `Unlock`, not `Lock` | expected | the runtime charges the delay where the holder releases; read the frames below it |
| `make sync` shows no `sync.(*Mutex).Lock` in locked mode | trace window shorter than one wait | `make sync-long`, or `make trace SECONDS=25`; the target warns and recaptures |
| profile shows tens of seconds in an 8 s window | expected | contention delay is summed across goroutines, not elapsed time |
| `speedup` ≈ 1 in **unlocked** mode too | `GOMAXPROCS=1`, or a 1-core container | `make one` prints `gomaxprocs`; Go 1.26 honours container CPU limits |
| `speedup` > `GOMAXPROCS` in unlocked mode | deadline-bounded work under oversubscription | expected — trust `peak_working` |
| `peak_working` > `WORK_ITEMS` in `/stats` | `/stats` is process-wide, `/compute` is per-request | both are correct; they answer different questions |
| locked mode shows `peak_working` > 1 | not possible with one mutex — the old build is still running | `make status`, then `make locked` |
| `go tool trace` opens on a blank timeline | captured with no load | `make trace`, not a bare `curl` |
| *View trace by proc* will not render | the timeline viewer is Chrome/Chromium-only | `make sync` and `make sched` are plain pprof |
| `no demo3-locked-trace/trace.out` | never captured, or captured in the other mode | `make trace`; files are named for the *running* mode |
| trace file is large | long window or high concurrency | lower `TRACE_SECONDS`; 8 s is enough to see the pattern |
| `/debug/flightrecorder` returns 500 | no `runtime/trace.FlightRecorder` | use `/debug/pprof/trace?seconds=8`; the log warns at startup |
| load run seems stuck | locked mode at `REQUESTS=24` is 38 s of queued work | that is the bug; `REQUESTS=8` keeps it to 12.8 s |
| `cancelled_batches` climbing | clients timed out; queued tasks cannot be cancelled | expected — see the mutex-cancellation note above |
| `port 8082 is already held by pid N` | stale run | `make clean` |

## Reset

```bash
make down     # stop the service
make reset    # zero the counters, leave it running
make clean    # stop, remove bin/ and .run/
```

Nothing persists outside `bin/`, `.run/` and `../artifacts/`. To discard the
captures too:

```bash
rm -rf ../artifacts/demo3-mutex-profile ../artifacts/demo3-locked-trace \
       ../artifacts/demo3-unlocked-trace
```
