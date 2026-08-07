# Screen recordings

Nine recordings of the demos being run on stage, one per live script.

Each was captured by running the script it is named after — the same commands, at
the pace the room would see them. Nothing is staged: every number on screen was
produced at record time, so a recording and a live run tell the same story with
the same numbers.

Demo 1 is a dashboard endpoint calling three independent services one after
another, where the trace waterfall shows a staircase instead of a stack. Demo 2 is
a handler leaking a goroutine per request, found as a gauge that rises and never
falls and diagnosed as a hundred identical `[chan send]` stacks. Demo 4 is an
endpoint taking seconds for a second of arithmetic, where the CPU profile accounts
for a fraction of the elapsed time and the answer turns out to be a cgroup CPU
quota — a file, not a profile.

They exist for the case the casts do not cover: a demo that needs a browser, a
venue machine that will not run Docker, or a talk given without the laptop that
recorded them. On stage, run the scripts — [`scripts/LIVE.md`](../scripts/LIVE.md)
— and keep these as the fallback.

| Recording | Script | Length | Ends on |
| --- | --- | --- | --- |
| `demo1-1-load.mp4` | [`live-demo1-1-load.sh`](../scripts/live-demo1-1-load.sh) | 14 s | Jaeger opens on the frontend's slowest traces |
| `demo1-2-fix.mp4` | [`live-demo1-2-fix.sh`](../scripts/live-demo1-2-fix.sh) | 22 s | the `Sequential` → `Concurrent` diff, then the same request |
| `demo2-1-metric.mp4` | [`live-demo2-1-metric.sh`](../scripts/live-demo2-1-metric.sh) | 16 s | the gauge still where the traffic left it, nothing in flight |
| `demo2-2-pprof.mp4` | [`live-demo2-2-pprof.sh`](../scripts/live-demo2-2-pprof.sh) | 13 s | a hundred `[chan send]` headers, then `server.go:176` |
| `demo2-3-fix.mp4` | [`live-demo2-3-fix.sh`](../scripts/live-demo2-3-fix.sh) | 17 s | the gauge back at baseline, `0` blocked |
| `demo4-1-request.mp4` | [`live-demo4-1-request.sh`](../scripts/live-demo4-1-request.sh) | 14 s | `9.35s total` — and nothing on screen saying why |
| `demo4-2-pprof.mp4` | [`live-demo4-2-pprof.sh`](../scripts/live-demo4-2-pprof.sh) | 57 s | a CPU profile accounting for a fraction of the elapsed time |
| `demo4-3-ebpf.mp4` | [`live-demo4-3-ebpf.sh`](../scripts/live-demo4-3-ebpf.sh) | 17 s | `sha256` → `schedule` with no syscall: preempted, not blocked |
| `demo4-4-cgroup.mp4` | [`live-demo4-4-cgroup.sh`](../scripts/live-demo4-4-cgroup.sh) | 24 s | `nr_throttled +95` → `+3`, and 9.35 s → 0.57 s on the same container |

Demo 3 has no recording. Its evidence is a `go tool trace` timeline and a
Prometheus graph, neither of which survives being watched rather than clicked —
run [`live-demo3-1-metrics.sh`](../scripts/live-demo3-1-metrics.sh) and its two
sequels, or fall back to [`casts/demo3.cast`](../casts/demo3.cast), which prints
every number in the terminal.

Demo 4's four acts are one sequence: play them in order. Acts 1 and 2 never name
the CPU quota — that is the answer, and a run that opens with `0.25 cores` has
been solved before the first tool comes out. Act 3 is the eBPF off-CPU profile,
and act 4 is the two `cat`s that name the cause.

## Play

The files are H.264 in MP4, so they play in a browser, in Quick Look, and inline
in these pages on GitHub. Nothing to install.

```bash
open videos/demo1-1-load.mp4
```

## Re-record

Screen-record the terminal while running the script the recording is named after:

```bash
./scripts/live.sh 1-1-load
```

They were captured on a Retina display and re-encoded down to 1920 wide at 30 fps,
which is where terminal text stays sharp and nine recordings still fit in about
five megabytes:

```bash
ffmpeg -i in.mov -vf "scale=1920:-2:flags=lanczos,fps=30" \
  -c:v libx264 -preset slow -crf 24 -pix_fmt yuv420p \
  -movflags +faststart -an out.mp4
```

`-an` drops the audio track: the recordings are narrated live, and a muted track
is weight with nothing in it. `+faststart` moves the index to the front of the
file so playback starts before the whole thing has downloaded.
