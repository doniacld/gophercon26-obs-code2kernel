# Demo 2 — a goroutine leak: detected by a metric, diagnosed by a profile

```bash
make before      # 100 cancelled requests -> ~100 goroutines left behind
make after       # the same requests -> back to baseline
make clean       # stop the server
```

On stage the same two runs are told in three acts — see
[three acts](#on-stage-three-acts) below.

| | |
| --- | --- |
| **Symptom** | nothing. Latency is fine, no request errors, the process just grows |
| **Detection** | `go_goroutines` on `/metrics` — the gauge climbs by 100 and stays |
| **Diagnosis** | `/debug/pprof/goroutine` — 100 identical stacks in `[chan send]` |
| **Root cause** | the worker is started with `context.Background()` and its send is not guarded by a `select` |
| **Fix** | pass the request context and put the send in a `select` with `ctx.Done()` |
| **Main lesson** | a request ending does not automatically stop the goroutines it created |

## What happens

Every request is deliberately cancelled: `curl --max-time 0.02` against a handler
whose work takes 90 ms, so the client always gives up first. That is not a
contrived condition — it is a user closing a tab, a load balancer timing out, a
client with a deadline.

The broken worker is started with `context.Background()`, so cancelling the
request does not stop it. It finishes its work and tries to hand the result back:

```go
results := make(chan Result)

go func() {
    result := doWork(context.Background())
    results <- result             // blocks forever
}()
```

By then the handler has returned on `<-r.Context().Done()`, and nobody is left to
receive from `results`. The send has no receiver and no way out, so the goroutine
parks there for the lifetime of the process. One hundred cancelled requests, one
hundred goroutines that will never run again.

And they stay. Nothing in Go reclaims a blocked goroutine: there is no timeout on
a channel send, and the garbage collector does not collect goroutines — a parked
one is a live one, still holding its stack and everything its closure captured.
`go_goroutines` reads `runtime.NumGoroutine()`, which counts goroutines that
exist, not goroutines that are doing anything. So the gauge does not drift back
down when the traffic stops, and waiting longer does not help: 30 seconds after
the last request the count is still 107, with 100 of them in `[chan send]`. Only
restarting the process gets them back, which is why the fix has to be in the code
rather than in the deploy.

Nothing outside the process shows this. The handler behaved correctly and
returned promptly; the leak is in what it left behind.

## Two endpoints, two questions

```text
/metrics
└── How many goroutines currently exist?

/debug/pprof/goroutine
└── What are those goroutines doing?
```

`go_goroutines` is a standard Prometheus runtime metric — the Go collector reads
`runtime.NumGoroutine()` and nothing in this demo counts anything itself:

```text
# HELP go_goroutines Number of goroutines that currently exist.
# TYPE go_goroutines gauge
go_goroutines 107
```

That gauge is what a dashboard would have alerted on, and it is also the limit of
what a gauge can tell you: a number is climbing. It cannot say which goroutines,
in what state, or on which line. For that you open the profile.

**The metric tells us what is growing. The profile tells us where it is stuck.**

## What the two tools show

`make before` scrapes `go_goroutines` before and after the requests, then asks the
goroutine profile what those goroutines are doing:

```text
BROKEN

Runtime metric before:
go_goroutines 7

Sending 100 requests that time out before work completes...

Runtime metric after:
go_goroutines 107

pprof diagnosis:
100 goroutines blocked on channel send

goroutine 131 [chan send]:
main.handleWorkBroken.func1()
	server.go:176
created by main.handleWorkBroken in goroutine 113
	server.go:174

(the other 99 are the same stack)
```

Four things to read, in order: the gauge went up by 100 and stayed there; the
state is `[chan send]`; the frame is `main.handleWorkBroken.func1`, this program's
own code and not the runtime's; and `server.go:176` is the line to go and fix.

The baseline is 6 or 7 on the authoring machine, varies between runs, and will
differ on yours — the two listeners, whichever connections are open at the moment
of the scrape, and the runtime's own housekeeping. Read the *growth*, not the
absolute number; nothing in the demo asserts a floor. The 100 is exact, because it
is one per cancelled request.

## The fix

Follow the request context, and never let the send be the thing that blocks:

```go
ctx := r.Context()
results := make(chan Result)

go func() {
    result, err := doWorkCancellable(ctx)
    if err != nil {
        return                    // cancelled: no result to deliver
    }

    select {
    case results <- result:
    case <-ctx.Done():
        return                    // nobody is listening any more
    }
}()
```

Two changes, and both are about cancellation. `doWorkCancellable` selects on
`ctx.Done()`, so the work itself stops instead of running on for a result nobody
will read. The send is in a `select` with `ctx.Done()`, so the goroutine has
somewhere to go when the receiver has left.

The channel stays unbuffered. A one-slot buffer would also unblock this
goroutine, but only because exactly one value is ever sent — it breaks again as
soon as there are two. The `select` says the actual rule: stop when the caller is
gone.

`make after` sends the identical 100 cancelled requests:

```text
FIXED

Runtime metric before:
go_goroutines 7

Sending the same 100 cancelled requests...

Runtime metric after:
go_goroutines 7

pprof diagnosis:
no accumulated application goroutines blocked on channel send
```

The gauge may land a goroutine or two above where it started — a connection still
closing is not a leak. What matters is that it comes back, and that the profile no
longer has a repeated application stack parked on a send.

## On stage: three acts

`make before` and `make after` print everything at once, which is right for a
rehearsal and wrong for a room: the audience never sees pprof being *reached for*.
Live, the same commands are split into three acts, each ending where the next one
begins.

```bash
make live         # act 1: the metric, read three times
make live-pprof   # act 2: the instrumentation diff, then the [chan send] stack
make live-fix     # act 3: the fix diff, the same load, the profile again
```

| Act | Starts the server as | On screen |
| --- | --- | --- |
| 1 — the metric | `serve.sh --metrics-only` | the gauge idle, a hundred requests, the gauge again, and again |
| 2 — the profile | `serve.sh` | `diagnosticsMetrics` → `diagnosticsProfiling` as a diff, the same traffic, every goroutine's state from `debug=2`, then one of those stacks in full |
| 3 — the fix | `serve.sh --fixed` | `handleWorkBroken` → `handleWorkFixed` as a diff, the same traffic, the same two profile commands |

Act 1 has no profiler at all — the process is started with `-pprof=false` — and it
does not go looking for one either. Instead it reads the gauge three times: idle,
after the traffic, and once more when the traffic is over.

That third reading is the act, and the scrape itself is what makes it land. `# TYPE
go_goroutines gauge` is on screen, so a room that knows what a gauge is knows this
number is a snapshot — it went up because work arrived, and a snapshot taken after
the work is gone should show it gone. It does not. There is no traffic and the
number is still where the traffic left it.

That is the position most services are in, and it is where the next act starts.

Nothing on screen mentions the 20 ms timeout or the 90 ms handler. Both `curl`
commands are there, so the facts are available; saying out loud what they add up to
is the speaker's, and it lands better once pprof has printed the stack than as a
prediction before it. Every narration line is the title of the command it precedes,
nothing more.

Both diffs are extracted from `server.go` at run time by
[`codediff`](../scripts/cast-lib.sh), so the code on screen is the code that just
ran. `diagnosticsMetrics` and `diagnosticsProfiling` both exist in the source for
that reason — the "before" side of act 2's diff has to be real code, and the
`-pprof` flag is what chooses between them.

Every act reads the gauge with the same one-line scrape and the profile with the
same two `curl` commands; they live in
[`../scripts/demo2-common.sh`](../scripts/demo2-common.sh) so nothing drifts
between acts and the numbers stay comparable. Recorded versions are in
[`casts/`](../casts/); the pacing is [documented](../scripts/LIVE.md) with demo 1's.

## Layout

```text
server.go        both handlers, both diagnostics servers, the whole demo
server_test.go   the leak, the fix, and that both endpoints answer
scripts/serve.sh start the server in one shape, wait until it answers
scripts/run-demo.sh  a whole run: serve, scrape, send, scrape, ask pprof
```

| Listener | Port | |
| --- | --- | --- |
| application | 8081 | `GET /work` |
| diagnostics | 6061 | `/metrics` · `/debug/pprof/*` |

Application traffic and diagnostics are on separate listeners, which is also why
the numbers are trustworthy: `:6061` stays answerable while `:8081` is saturated.

Everything on screen comes from `github.com/prometheus/client_golang` and
`net/http/pprof`. There is no counter in the server, no `/stats` endpoint and no
load generator. The gauge is scraped:

```bash
curl -s http://localhost:6061/metrics | grep go_goroutines
```

```text
# HELP go_goroutines Number of goroutines that currently exist.
# TYPE go_goroutines gauge
go_goroutines 107
```

`grep` rather than an `awk` that prints the value alone: the two extra lines are
Prometheus documenting its own metric, and both of them earn their place on the
slide. `currently exist` and `gauge` say this is a snapshot — which is exactly why
reading it again after the traffic has stopped is a fair question to ask, and why
the answer not changing is the whole of act 1.

Act 2 reads `debug=2` twice, and never `debug=1`. `debug=1` collapses identical
stacks into a `100 @ 0x...` count and drops the state, which is the one field the
demo is about: a count says something grew, a state says what it is waiting for.
The first read greps the dump down to its `goroutine N [state]:` headers — a roll
call of one `[running]`, a few `[IO wait]`, and a hundred `[chan send]`. The second
opens one of those stanzas, which is where `server.go:176` appears, and it is only
persuasive to a room that has already seen the hundred headers it came from.

Both have the directory prefix and the `+0x4f` offsets trimmed so they fit a
projector.

The Go collector is registered on a **dedicated** registry, not
`prometheus.DefaultRegisterer` — client_golang's own `init` already installs the Go
and process collectors there, and registering them twice panics.

Both modes are the same binary: `-mode broken` and `-mode fixed` choose which
handler is registered on `/work`, and `-pprof=false` serves `/metrics` alone —
which is what act 1 needs and what most services actually look like.

`scripts/serve.sh` wraps those flags for the stage, and defaults to the version
with the bug:

```bash
./scripts/serve.sh --metrics-only    # act 1: /metrics and nothing else
./scripts/serve.sh                   # act 2: the same handler, plus pprof
./scripts/serve.sh --fixed           # act 3: the corrected handler
```

Broken is the default, and nothing is echoed back about which mode is running, for
one reason: these commands are typed on screen. A `broken` on the first line of act
1 answers the question the audience is supposed to spend three acts answering.

```bash
go test -race ./...   # or: make test
```

## Why it takes both tools

A goroutine leak has no signal in the places you would normally look. Request
latency is unaffected — the handler returns on time. The error rate is unaffected
— the client cancelled, so there was no error to report. Memory grows, slowly and
without an obvious culprit, because each leaked goroutine holds a stack and
whatever its closure captured.

`go_goroutines` is the one signal that does move, and it is cheap enough to scrape
every fifteen seconds forever. That is its job: it is how you find out at all, from
a dashboard, without knowing in advance what to look for. It is also all it can do
— a gauge has no stack in it.

The goroutine profile is the other half, and it is not something you scrape
continuously. You take it once, when the gauge has already told you where to look,
and it groups by stack: a hundred goroutines sitting on the same line is not a
pattern you have to go hunting for, it is the first thing in the output.

Detection and diagnosis are different jobs, and this demo is the smallest case
where using the wrong tool for either one leaves you stuck.
