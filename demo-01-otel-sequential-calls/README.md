# Demo 1 — OpenTelemetry: independent calls made sequentially

A dashboard endpoint needs three things from three services. It asks for them one
at a time, and nobody notices until they look at the shape of the trace.

| | |
| --- | --- |
| **Symptom** | `GET /dashboard` takes ~766 ms |
| **Main evidence** | Jaeger trace waterfall — three child spans in a staircase |
| **Root cause** | three independent calls issued one after another |
| **Fix** | `errgroup.WithContext` |
| **Result** | 766 ms → 323 ms average, 6.5 → 15.5 req/s, identical work |
| **Main lesson** | tracing reveals the *structure* of request execution; independent work performed sequentially makes end-to-end latency additive |

This is an application-control-flow bug, not an instrumentation bug. Both modes
emit exactly the same spans with the same names and the same attributes. Only
their arrangement on the timeline changes — which is the point, because that
arrangement is the one thing a waterfall shows immediately and a latency metric
never will.

## Layout

| Component | Port | Endpoints |
| --- | --- | --- |
| `frontend` | 8080 | `GET /dashboard`, `GET /healthz` |
| frontend diagnostics | 6060 | `/debug/pprof/*`, `/debug/runtime` |
| `profile-service` | 8085 | `GET /fetch` — 180 ms |
| `recommendation-service` | 8086 | `GET /fetch` — 250 ms |
| `inventory-service` | 8087 | `GET /fetch` — 320 ms |
| Jaeger UI | 16686 | started by the root `Makefile` |
| Jaeger OTLP/HTTP | 4318 | |

```
cmd/frontend         GET /dashboard — sequential in broken mode, concurrent in fixed
cmd/dependency       GET /fetch — one binary, started three times
cmd/loadgen          deterministic load
internal/dashboard   Sequential() and Concurrent(), the whole demo
internal/telemetry   OTLP exporter, resource attributes, propagator
```

180 + 250 + 320 = **750 ms sequential**, against **320 ms concurrent**. The three
latencies are deliberately unequal so the staircase has three visibly different
step widths instead of three identical blocks.

The three dependencies are one binary started three times with different `-name`
and `-latency`. Keeping them identical in every other respect means any
difference the audience sees in the trace comes from the frontend's control flow
and nothing else.

## Run it

Start Jaeger once, from the repository root:

```bash
make up          # docker compose up -d, waits for Jaeger to be ready
```

Then from this directory:

```bash
make broken      # three dependencies + a frontend that calls them in turn
make one         # a single request, with its total time
make load        # 20 requests at concurrency 5
make trace       # print the slowest trace of the running mode as a waterfall
```

and the fixed side:

```bash
make fixed
make one
make load
make trace
```

Or from the repository root: `make demo1-broken`, `make demo1-fixed`,
`make demo1-load`.

### Exact commands, if you prefer them explicit

```bash
go build -o bin/frontend   ./cmd/frontend
go build -o bin/dependency ./cmd/dependency
go build -o bin/loadgen    ./cmd/loadgen

./bin/dependency -addr :8085 -name profile-service        -latency 180ms -mode broken &
./bin/dependency -addr :8086 -name recommendation-service -latency 250ms -mode broken &
./bin/dependency -addr :8087 -name inventory-service      -latency 320ms -mode broken &

./bin/frontend -addr :8080 -diag-addr :6060 -mode broken \
  -profile-url        http://localhost:8085/fetch \
  -recommendation-url http://localhost:8086/fetch \
  -inventory-url      http://localhost:8087/fetch &

curl -s localhost:8080/dashboard | jq .
./bin/loadgen -url http://localhost:8080/dashboard -requests 20 -concurrency 5
```

`-mode fixed` on the frontend is the only change between the two modes. The
dependencies take `-mode` purely so their spans carry the right `demo.mode`
attribute for filtering.

### Capturing the evidence

```bash
# terminal waterfall, no browser required
python3 ../scripts/dump-trace.py frontend --slowest --mode broken
python3 ../scripts/dump-trace.py frontend --slowest --mode fixed

# the Jaeger UI
open http://localhost:16686        # service: frontend, operation: GET /dashboard

# the raw API
curl -s 'http://localhost:16686/api/traces?service=frontend&limit=20' \
  | jq '.data[0].spans[].operationName'
```

`make trace` sleeps 2 s first. That is not padding — the SDK batches spans with a
1 s timeout, so an immediate query returns a half-exported trace with a missing
root and holes that have nothing to do with the demo.

## Expected output

### Broken

```
$ make one
{
  "mode": "broken",
  "strategy": "sequential",
  "total_ms": 763.61,
  "sum_of_dependency_ms": 762.883,
  "slowest_dependency_ms": 322.875,
  "results": [ ... ]
}

  <- 0.763954s total
```

```
$ make load
requests=20 concurrency=5 ok=20 errors=0 wall=3.073s
  latency  min=755.9ms  avg=765.8ms  p50=760.5ms  p95=777.8ms  p99=777.8ms  max=778.0ms
  throughput 6.5 req/s
  status 200=20
```

Note `total_ms` ≈ `sum_of_dependency_ms`. The response body diagnoses itself
before anyone opens a trace. Note also how tight the distribution is — p50 to max
spans 18 ms — so nobody can attribute the latency to a cold cache or an unlucky
sample.

```
$ make trace
trace 1ba8ea8c1d1d1c0c0aa0b1c8b0e3ff40  total=775.6ms  spans=13

  GET /dashboard                 frontend                   775.6ms  |############################################
    fetch profile-service        frontend                   192.4ms  |##########
      HTTP GET                   frontend                   192.4ms  |##########
        GET /fetch               profile-service            180.1ms  |##########
          profile-service.query  profile-service            180.1ms  |##########
    fetch recommendation-service frontend                   253.4ms  |          ##############
      HTTP GET                   frontend                   253.3ms  |          ##############
        GET /fetch               recommendation-service     251.2ms  |          ##############
          recommendation-service.query  recommendation-service  250.7ms  |          ##############
    fetch inventory-service      frontend                   328.4ms  |                        ##################
      HTTP GET                   frontend                   328.4ms  |                        ##################
        GET /fetch               inventory-service          323.8ms  |                        ##################
          inventory-service.query inventory-service         323.7ms  |                        ##################

  root span                     775.6ms
  sum of child spans            774.2ms   (3 children)
  wall clock they cover         774.2ms
  concurrency factor             1.00   sequential — a staircase

  The children never overlapped. End-to-end latency is their sum.
```

Every `#` block starts where the previous one ends. That is the staircase, and it
is the whole demo.

**The concurrency factor is the diagnosis in one number.** It is
`sum(child durations) / (last end − first start)`: the average number of child
spans in flight while any of them was running. 1.00 means they never overlapped.
It is computed from span timestamps alone, so it works on any trace from any
backend.

The trace does not merely show that the request was slow. It shows *why*: the
second call could have started at t=0 and instead started at t=192 ms.

### Fixed

```
$ make load
requests=20 concurrency=5 ok=20 errors=0 wall=1.290s
  latency  min=320.5ms  avg=322.8ms  p50=322.0ms  p95=326.5ms  p99=326.6ms  max=326.6ms
  throughput 15.5 req/s
  status 200=20
```

```
$ make trace
  root span                     324.6ms
  sum of child spans            763.0ms   (3 children)
  wall clock they cover         324.3ms
  concurrency factor             2.35   overlapping

  The children ran at the same time. Latency is the slowest one.
```

In the waterfall the three bars now start at the same x position and end at
different ones.

Read those two lines together: the children still sum to 763 ms of work, and they
now fit inside 324 ms of wall clock. Nothing got faster. The waiting was
overlapped.

| | broken | fixed |
| --- | --- | --- |
| avg latency | 765.8 ms | 322.8 ms |
| p50 | 760.5 ms | 322.0 ms |
| p95 | 777.8 ms | 326.5 ms |
| throughput at concurrency 5 | 6.5 req/s | 15.5 req/s |
| sum of child spans | 774 ms | 763 ms |
| wall clock covered | 774 ms | 324 ms |
| **concurrency factor** | **1.00** | **2.35** |

Both sides land inside the expected bands (700–900 ms and 320–400 ms) with room
to spare, on an otherwise idle laptop.

The factor is 2.35 rather than 3.00 because the three dependencies have different
durations: the 180 ms call has finished while the 320 ms one is still running, so
the average number in flight across the window is below three. A factor near 1 is
the diagnosis; the exact value above 1 is not interesting.

## The diff

```go
// broken — latency is the sum of the calls
for i, dep := range c.Dependencies {
    res, err := c.fetch(ctx, dep)
    if err != nil {
        return nil, fmt.Errorf("%s: %w", dep.Name, err)
    }
    results[i] = res
}

// fixed — latency is the slowest call
g, gctx := errgroup.WithContext(ctx)
for i, dep := range c.Dependencies {
    g.Go(func() error {
        res, err := c.fetch(gctx, dep)
        if err != nil {
            return fmt.Errorf("%s: %w", dep.Name, err)
        }
        results[i] = res
        return nil
    })
}
if err := g.Wait(); err != nil {
    return nil, err
}
```

Read the broken loop and note what is missing: nothing. There is no lock, no
shared state, no ordering requirement between the three calls. The second call
waits for the first purely because it is written on the next line — and that is
enough to make end-to-end latency additive. This survives code review because a
loop over dependencies is exactly what the problem looks like when you describe
it in words.

`errgroup.WithContext` rather than a bare `sync.WaitGroup`, for three reasons
that all matter in production:

1. **the first error is returned** — a failing dependency fails the request
   instead of leaving a zero value in the response;
2. **the derived context is cancelled on the first error** — the siblings stop
   rather than finishing work whose result is already discarded;
3. **`Wait` returns only after every goroutine has** — so no goroutine is still
   writing to `results` after the function returns, and no goroutine outlives the
   request.

Each goroutine writes `results[i]` and nothing else. Distinct indices in a
preallocated slice are independent memory, so no mutex is needed and the ordering
of the response is preserved regardless of which call finishes first. Every test
in the package runs under `-race` to confirm it.

`gctx`, not `ctx`, inside `g.Go` — passing the outer context would keep the
siblings running after a failure and lose point 2 entirely, while still compiling
and still passing a happy-path test.

## Attributes

| Attribute | On | Cardinality |
| --- | --- | --- |
| `demo.mode` | every span | 2 |
| `dependency.name` | `fetch *`, dependency spans | 3 |
| `http.route` | root span | 1 per route |
| `service.version` | root span | 1 per build |
| `dependency.elapsed_ms`, `dashboard.total_ms`, `dashboard.sum_of_dependency_ms`, `dashboard.slowest_dependency_ms` | as measured | millisecond buckets |

All bounded by configuration or rounded to milliseconds. Nothing here carries a
request ID, a user ID, a full URL with a query string, or a nanosecond duration —
attributes are indexed by the backend, so unbounded values are unbounded cost.
The test for whether an attribute belongs: *would I ever group by this?*
`dependency.name` yes. `request.id` no — you filter by it once and never
aggregate on it, so it belongs in a span event or a log correlated by trace ID.

Span names are route patterns (`GET /dashboard`, `GET /fetch`), never request
paths. A distinct operation name per request makes a service unfindable in
Jaeger's operation list.

## What the trace reveals, and what it does not

**Reveals:** the structure of one request across four services — what called
what, in what order, with how much overlap, and where the time sat. Nothing else
in this repository can show the *shape* of execution across a process boundary.
That shape is what turns "the dashboard is slow" into "the calls are serialised",
which is a fixable statement.

**Does not reveal:**

- **Why any single span took as long as it did.** `inventory-service.query` is
  320 ms; the trace does not say whether that was CPU, a lock, a slow disk, or a
  `time.Sleep`. Demos 2, 3 and 4 exist because that question needs different
  tools.
- **Anything nobody instrumented.** A trace records the spans you created. An
  uninstrumented call does not appear, and a gap in a waterfall is
  indistinguishable from a fast dependency with a slow client. Auto-instrumentation
  covers recognisable boundaries — an HTTP round trip, a SQL query — and nothing
  else. Anywhere your code waits *for permission* to start one of those (a pool, a
  limiter, a lock, a retry backoff) is a place you must instrument yourself.
- **Aggregate behaviour.** One trace is one request. `make load` produces 20 of
  them, and Jaeger will happily show a different one than you meant — which is
  why `make trace` filters by the running mode and takes the slowest.
- **What the process was doing between spans.** In-process time is opaque to a
  tracer at this granularity; that is a profiler's job.

`AlwaysSample` here is right for a demo and wrong for production. Two things
worth knowing: make the sampling decision once at the start of the trace and
propagate it (the code uses `ParentBased(AlwaysSample())`, the correct shape with
a head sampler swapped in) — independent per-service decisions produce traces
with holes that look exactly like missing instrumentation. And tail sampling,
which is what you actually want here because the interesting traces are the rare
slow ones, lives in the Collector rather than the SDK.

## A caveat worth saying out loud

Concurrent fan-out increases *instantaneous* downstream load. Broken mode sends
the three dependencies 6.5 requests per second between them; fixed mode sends
15.5 each, arriving in bursts of three. Here that is free, because the
dependencies are idle. In production it means:

- a dependency comfortable at your sequential rate may not be at your concurrent
  one, and you have moved the bottleneck rather than removed it;
- retry storms fan out too;
- N calls from M concurrent requests is N×M sockets, and connection pools have
  limits — `MaxConnsPerHost` will queue you silently.

Parallelism is a decision about load, not just latency. Make it deliberately.
Demo 2 is the direct consequence of taking it too far: fan-out with no bound at
all.

## Speaker flow (3–5 minutes)

1. **Run broken mode.** `make broken`. Read the startup line aloud — it prints
   the mode and the three latencies, so the setup is on screen and not just in
   the narration.
2. **Send one request.** `make one` → 763 ms. Then `make load` → avg 766 ms, p95
   778 ms, 6.5 req/s. Stable to within 20 ms.
3. **Open the trace.** `make trace`, or the Jaeger UI on `GET /dashboard`.
4. **Point to the staircase.** Three bars, each starting where the previous one
   ended. Point at the empty space to the left of the second and third bars: that
   is the time each call spent waiting for its turn. Concurrency factor 1.00.
5. **Explain that the dependencies are independent.** Nothing the profile service
   returns is an input to the recommendation call. There is no reason for the
   ordering. Ask the room: "180, 250 and 320 milliseconds — where did 763 come
   from?" Someone will say "it added them up."
6. **Show the sequential code.** `internal/dashboard/dashboard.go`, six lines.
   No lock, no shared state, no ordering requirement.
7. **Start fixed mode.** `make fixed`. Show the `errgroup` version and say why it
   is not a `WaitGroup`: errors, sibling cancellation, no leaked goroutines.
8. **Send the same request.** `make one` → 323 ms; `make load` → avg 323 ms,
   15.5 req/s.
9. **Show overlapping spans.** `make trace`. Three bars starting at the same x
   position. Concurrency factor 2.35.
10. **Compare end-to-end latency.** 766 ms → 323 ms, 2.4× on latency and 2.4× on
    throughput, with the same three calls to the same three services. *The trace
    did not tell me the service was slow — I already knew that. It told me the
    shape of the slowness, and the shape was a staircase.* Then the caveat: those
    calls now arrive all at once, and that is a load decision.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `no OTLP collector on localhost:4318` | Jaeger is not running | `make up` at the repository root |
| `no traces for service 'frontend'` | queried before the batch flushed | wait 2 s and retry; `make trace` already sleeps. Check `.run/frontend.log`, and that `curl localhost:16686/api/services` lists `frontend` |
| Waterfall shows a **staircase after `make fixed`** | you are looking at a broken-mode trace — Jaeger keeps them all and the broken ones are by definition the slowest, so `--slowest` alone finds them first | `make trace` filters on the mode `stage.sh` recorded; by hand, pass `--mode fixed` |
| Root span missing, spans look orphaned | half-exported batch | wait 2 s and retry |
| `port 8085 is already held by pid N` | stale process from an earlier run | `make clean`, or `make status` to see who holds each port |
| Latency well above 780 ms in broken mode | something else is loading the machine, or a dependency was started with the wrong latency | `make logs` prints the `latency` each service booted with |
| Fixed mode is barely faster than broken | the frontend is not actually in fixed mode | `cat .run/mode`, and check the frontend's startup log line |
| `conflicting Schema URL` at startup | the `semconv` import does not match the SDK's `resource.Default()` | the version is pinned in `internal/telemetry/telemetry.go`; bump both together |
| Jaeger UI unreachable, projector or wifi failing | — | `make trace` is terminal-only and reads Jaeger's query API directly; nothing in this demo needs a browser |

## Fallback artifacts

```bash
make capture      # writes ../artifacts/demo1-<running mode>-trace/waterfall.txt
```

Jaeger's memory storage dies with its container, so a text waterfall is the only
demo-1 fallback that survives a restart. Capture both modes during rehearsal:

```bash
make broken && make load && make capture
make fixed  && make load && make capture
cat ../artifacts/demo1-broken-trace/waterfall.txt
```

The artifact is written with `--no-color`: ANSI escapes in a committed file turn
`cat` output into noise and make it useless in a diff.

`make compare` runs both modes back to back and prints both waterfalls in one
command — for rehearsal, and for the moment a live sequence has gone sideways and
you need the result on screen quickly.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `MODE` | `broken` | `broken` \| `fixed` |
| `PROFILE_LATENCY` | `180ms` | profile-service delay |
| `RECS_LATENCY` | `250ms` | recommendation-service delay |
| `INVENTORY_LATENCY` | `320ms` | inventory-service delay |
| `REQUESTS` | `20` | loadgen requests |
| `CONCURRENCY` | `5` | loadgen workers |
| `OTLP_ENDPOINT` | `localhost:4318` | collector |
| `JAEGER_URL` | `http://localhost:16686` | query API |

For a large room, widen the gap:

```bash
make broken INVENTORY_LATENCY=600ms     # 1030ms broken vs 600ms fixed
```

## Tests

```bash
make test         # go test -race ./...
```

Six checks, because a demo claiming "same work, less time" should be made to
prove both halves:

- `TestBothModesReturnTheSameData` — identical results, same order, identical
  bodies. Concurrency did not change the answer.
- `TestConcurrentIsFasterThanSequential` — sequential takes at least the sum,
  concurrent comfortably under it, and the **peak in-flight count is 1 versus 3**.
  That last assertion tests the mechanism rather than the outcome, so the test
  cannot pass for the wrong reason on a fast machine.
- `TestConcurrentCancelsSiblingsOnFailure` — when one dependency fails, a slow
  sibling is cancelled rather than waited out. This is the assertion that would
  fail if someone passed `ctx` instead of `gctx`.
- `TestSequentialStopsAtTheFirstError` — broken mode also fails fast, for the
  trivial reason that it had not started the other calls yet.
- `TestResponseArithmetic` — `total ≈ sum` sequentially, `total ≈ slowest`
  concurrently. The numbers the audience reads off the response body.
- `TestContextCancellationPropagates` — both modes honour a cancelled request
  context, checked through the error chain rather than by string match.

The fake dependencies use an explicit `http.Transport` with a per-host connection
limit above the dependency count, so client-side queueing can never be mistaken
for the serialisation the tests are measuring.

## Reset

```bash
make down         # stop all four processes
make clean        # stop, and remove bin/ and .run/
make -C .. down   # stop Jaeger too
```

`docker compose restart jaeger` at the repository root clears stored traces if an
earlier run's data is in the way.
