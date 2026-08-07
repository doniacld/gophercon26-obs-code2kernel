# Screencasts

One asciicast per demo, recorded by running that demo's own `make` targets in the
order its README gives them. Nothing is staged or replayed: every number on
screen was produced live at record time, so a cast and a live run tell the same
story with the same numbers.

| Cast | Demo | Length | Size | Sequence |
| --- | --- | --- | --- | --- |
| `demo1-load.cast` | 1a — one request, read the trace in Jaeger | 16 s | 120×40 | `curl -sv /dashboard` · Jaeger link |
| `demo1-fix.cast` | 1b — the change, then the same request again | 20 s | 120×40 | diff `Sequential`/`Concurrent` · `curl -sv /dashboard` · Jaeger link |
| `demo1.cast` | 1 — OTel, independent calls made sequentially | 43 s | 120×40 | `broken` · `one` · `load` · `trace` · `fixed` · `one` · `load` · `trace` |
| `demo2-metric.cast` | 2a — a number that should not be moving, moving | 38 s | 120×40 | `serve --metrics-only` · gauge · 100 requests · gauge · gauge |
| `demo2-pprof.cast` | 2b — the instrumentation, then the stack | 54 s | 120×40 | diff `diagnosticsMetrics`/`diagnosticsProfiling` · `serve` · 100 requests · gauge · `debug=1` · `debug=2` |
| `demo2-fix.cast` | 2c — the fix, the same load, the same profile | 51 s | 120×40 | diff `handleWorkBroken`/`handleWorkFixed` · `serve --fixed` · 100 requests · gauge · `debug=1` · blocked count |
| `demo2.cast` | 2 — a goroutine leak: `go_goroutines`, then pprof | 14 s | 120×40 | `before` · `after` |
| `demo3.cast` | 3 — lock contention, concurrent is not parallel | 68 s | 170×40 | `broken` · `one` · `load` · `profile-mutex` · `sync` · `fixed` · `one` · `load` · `profile-mutex` |
| `demo4.cast` | 4 — the code is innocent, a CPU quota is the bug | 151 s | 130×40 | `broken` · `load` · `profile-cpu` · `throttle-stats` · `fixed` · `load` · `throttle-stats` · `compare` |

`demo1-load` and `demo1-fix` are the recordings of the pair meant to be run live:
the first ends on a Jaeger link and says nothing about the cause, so the audience
reads the waterfall and diagnoses it out loud before the second one shows the
diff. On stage, run the scripts rather than the casts — `make demo1-live` and
`make demo1-live-fix`, documented in [`scripts/LIVE.md`](../scripts/LIVE.md) —
which do the same thing paced by the speaker, against a real Jaeger UI.

`demo1.cast` is the self-contained version that prints the waterfall in the
terminal — the fallback for when a projector will not show a browser.
`demo1-original.cast` is the recording `demo1.cast` was made from, kept as a
backup.

`demo2-metric`, `demo2-pprof` and `demo2-fix` are one sequence: play them in that
order. Act 1's server is started with `-pprof=false`, so there is no profile to be
had, and it ends on the gauge read a third time with no traffic in flight — still
where the traffic left it. Act 2 adds the profiler as a code diff and reads the
stack; act 3 fixes the line the stack named.

None of them says the cause before act 2's profile prints it: every line of
narration names the command it is about to run, and nothing else. If you edit
these, keep that — the recording exists to show a tool saying something, not a
presenter saying it first.

The live versions are `make demo2-live`, `demo2-live-pprof` and `demo2-live-fix`.
`demo2.cast` is the two-command version — `make before` and `make after`,
everything printed at once — kept as the compact fallback.

Widths are per demo, set by the widest line that matters. Demo 1's trace
waterfall is 114 columns and wrapping it destroys the one thing the demo exists
to show. Demo 3 prints pprof frames carrying a full package path, which reach 166.

## Play

```bash
asciinema play casts/demo1.cast
asciinema play -s 2 casts/demo1.cast     # twice as fast
```

## Re-record

```bash
# The demo 1 pair records one curl each and nothing else, so Jaeger and the
# services must already be running, in the right mode, when each one starts:
make up
make -C demo-01-otel-sequential-calls before && ./scripts/record-cast.sh 1-load
make -C demo-01-otel-sequential-calls after  && ./scripts/record-cast.sh 1-fix
./scripts/record-cast.sh 1     # needs Jaeger: `make up` at the repository root

# Demo 2's three acts start and stop their own server, in the shape each needs:
./scripts/record-cast.sh 2-metric
./scripts/record-cast.sh 2-pprof
./scripts/record-cast.sh 2-fix
./scripts/record-cast.sh 2
./scripts/record-cast.sh 3
./scripts/record-cast.sh 4     # needs Docker: the subject is a cgroup
```

Each script starts and stops its own demo. Two targets are deliberately absent:
`make view` (demo 3) opens a browser and blocks — `make sync` is the README's own
terminal-only substitute for it — and `make investigate` (demo 4) only runs on
Linux with root, so the cast records it there and skips it elsewhere.

The pacing is the recording's, not the script's: `TYPE` is the per-character
typing delay and `PAUSE` scales every pause. Both exist so a cast can be checked
without sitting through it:

```bash
TYPE=0 PAUSE=0 ./scripts/cast-demo1.sh     # run the sequence at full speed
./scripts/cast-check.py casts/demo1.cast   # what a recording actually contains
```

## How the highlighting works

`scripts/cast-lib.sh` holds the shared style, so all casts look alike. Each
`make` command names the lines worth emphasising — the ones its README asks the
audience to read — and `mark` puts them in reverse video as the real output
streams past. It selects lines; it never rewrites them.
