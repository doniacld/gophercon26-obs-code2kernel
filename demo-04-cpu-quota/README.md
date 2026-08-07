# Demo 4 — the missing time: what a CPU profile cannot see

|                   |                                                                                                              |
|-------------------|--------------------------------------------------------------------------------------------------------------|
| **Symptom**       | `POST /compute {"jobs":16}` takes ~7 s to do ~1.2 core-seconds of arithmetic. No lock, no I/O, no sleep.      |
| **Step 1**        | The Go CPU profile accounts for only a fraction of the elapsed time.                                          |
| **Step 2**        | An off-CPU flame graph shows where time accumulated *while the process was not running*.                       |
| **Step 3**        | `cpu.stat` confirms the container was CPU-throttled.                                                          |
| **Fix**           | A quota sized from measured demand. Not the removal of the quota.                                              |
| **Main lesson**   | A CPU profile only sees work while the process is running. Kernel-level observability finds the missing time.   |

## Run it

```bash
make before        # the symptom: one request, and it takes seconds
make investigate   # CPU profile, then the off-CPU flame graph
open ../artifacts/demo4/offcpu.svg
make after         # cpu.stat confirms it, then the quota corrected
```

Those three compose the narration, with the reading printed alongside the output.
Right for a rehearsal or for validating a venue machine.

On stage, nothing is wrapped. The three acts type the real commands — `docker
compose up`, `curl`, `go tool pprof`, `offcputime-bpfcc`, `cat` — because the
finding is that after an eBPF program and a flame graph, the thing that names the
cause is a *file*, and `docker exec … cat /sys/fs/cgroup/cpu.stat` says so where
`make cgroup` would hide it:

```bash
make demo4-live          # from the repository root
make demo4-live-offcpu
make demo4-live-quota
```

They all live in [`../scripts/demo4-common.sh`](../scripts/demo4-common.sh) as
command strings, so the three acts type the identical thing. The granular targets
are still here for running one step by hand:

```bash
make up            # stage the baseline service (MODE=corrected for the fix)
make request       # POST /compute once, and time it
make bench         # what one job costs, outside any container
make capture       # pprof CPU profile + BCC offcputime, over one window
make cpu-top       # what the process did while it was running
make offcpu        # where time accumulated while it was NOT running
make cgroup        # cpu.max and cpu.stat, as the kernel wrote them
```

**Nothing before `cgroup` names the quota.** Not its value, not the word
"throttle". The quota is the answer, and the audience is meant to reach it from
the profiles: `before` shows a slow request without saying what it runs under, and
`investigate` gets as far as *runnable and not running*, which is a hypothesis.

That rule is why the bugged mode is called **`baseline`** rather than `throttled`,
everywhere: the compose service key, the compose profile, the container name, the
`MODE=` argument and the `-label` the service echoes as `"mode"` in every reply.
All of them are typed or printed on stage — `docker compose --profile baseline up
-d --wait` is act 1's first command, `docker exec gcdemo-demo4-baseline cat …` is
act 3's, and the first reply carrying `"mode": "baseline"` is on screen before any
tool has been used. Naming one of them `throttled` would answer the demo there.

It is also just true: `baseline` is the state the service is in when the complaint
arrives, and what the corrected quota gets measured against.

`cpu.max` and `cpu.stat` are read in act 3 only, and `make cgroup` is the only
target that reads them — it runs at the top of `after`, against the container that
is still under the wrong quota, before the corrected one is staged, so it confirms
the hypothesis instead of announcing the cause.

## The narrative

1. **The request is slow.** ~7 s for work that costs ~1.2 core-seconds.
2. **The CPU profile explains only the time spent running.** It is accurate, and
   it accounts for a fraction of the latency. A pprof CPU profile is built from
   `SIGPROF` signals delivered to threads *while they are on a CPU*; a thread the
   kernel refuses to schedule receives no signal, so the missing time is invisible
   **by construction, not by oversight**.
3. **The off-CPU flame graph shows where time accumulated while not running.**
   This is the question no in-process profiler answers: not "where did this
   process spend CPU?" but "where did it spend elapsed time it was not executing?"
4. **`cpu.stat` confirms repeated cgroup CPU throttling.** `nr_throttled` against
   `nr_periods` is the kernel's own accounting of how many enforcement periods
   ended with runnable work forbidden to continue. This is the first time the
   quota appears on screen: read any earlier it would end the investigation before
   step 2 had a chance to be interesting.
5. **Correcting the quota fixes the same request.** ~7 s becomes ~0.4 s, with an
   identical digest — so the work provably did not change.

Measured on an Apple M3 Pro, Docker Desktop, `--cpus=0.25` against `--cpus=3`:

|                              |   baseline | corrected |
|------------------------------|-----------:|----------:|
| `cpu.max`                    | `25000 100000` | `300000 100000` |
| quota                        | 0.25 cores |   3 cores |
| `POST /compute {"jobs":16}`  |     7.36 s |    403 ms |
| `cpu.stat` delta, one request | 70 periods, 69 throttled | 5 periods, 0 throttled |
| digest                       | `fc8a486d9228e20e…` | `fc8a486d9228e20e…` |

The digest row is the one that makes the comparison mean anything: both runs
compute the same answer, so "faster" cannot mean "did less".

The `cpu.stat` row is a **delta**, not a single read, and act 3 takes it that way —
`cat`, one request, `cat` again. The file is cumulative since the container
started, so one read carries every idle 100 ms period since it booted, and an idle
process cannot be throttled: measured directly, 20 s of doing nothing moved
`nr_periods` from 168 to 212 while `nr_throttled` stayed at 2. Subtracting two
reads around one request removes all of that, and what is left is the request.

Acts 1 and 2 print neither the quota nor a throttle count: both belong to the
confirmation rather than to the symptom. Act 3 reads them, and on a Lima Ubuntu
24.04 VM (Linux 6.8.0-63, 4 CPUs) act 2 recorded 2.34 s of CPU samples in a
10.51 s window against 17.28 s of request-path off-CPU time — with every one of
the 114 request-path stacks reaching `schedule()` through an interrupt, no syscall
in the path. See
[`../artifacts/demo4/offcpu-summary.md`](../artifacts/demo4/offcpu-summary.md).

## Takeaways

> **A CPU profile only sees work while the process is running. Kernel-level
> observability helps investigate the missing time.**

Supporting:

> The off-CPU flame graph shows *where* time accumulated. `cpu.stat` tells us
> that CPU quota throttling was the *cause*.

Those are two separate claims on purpose. The flame graph localizes the wait; it
does not, on its own, prove *why* the CPU was withheld. `cpu.stat` is what names
the cause, and it is a plain file read — no privileges, no tooling.

## What changes between before and after

```diff
   baseline:
     image: gcdemo-demo4-service:latest
     deploy:
       resources:
         limits:
-          cpus: "3"
+          cpus: "0.25"
```

That is the entire diff, and it is a Compose file rather than a Go file. Same
image, same digest, same entrypoint, same endpoint, same request body, same job
count, same machine. Only the cgroup quota differs.

**The fix is a correct quota, not the absence of one.** A service with no CPU
limit is a service that can starve its neighbours.

## The request

```
POST /compute
{"jobs": 16}
```

16 CPU-bound workers, ~73 ms of one core each (`JobRounds` = 3000 rounds of
SHA-256 over a 64 KiB buffer), so ~1.17 core-seconds per request. The handler
starts all of them and waits for all of them.

16 jobs rather than 1 is what makes the off-CPU capture worth doing: sixteen
runnable goroutines against a quarter of a core means most of them are parked
waiting for CPU at any instant, and that wait is the time the flame graph is
drawn from.

`internal/hash` has no mode parameter and no branch on anything environmental.
`hash_test.go` asserts the combined digest is identical across `GOMAXPROCS` 1, 2
and 4 and under `-race`, so "the work is the same in both modes" is a test rather
than a claim.

## Requirements

`make before` and `make after` need **Docker** — the subject is a cgroup, and a
container is how you get one.

`make investigate` additionally needs:

| Requirement                | Why                                                     |
|----------------------------|---------------------------------------------------------|
| **Linux host or Linux VM** | eBPF is a kernel technology; see the note below         |
| **root** (via `sudo`)      | loading an eBPF program and reading other processes' stacks are privileged |
| **BCC tools**              | `offcputime-bpfcc` or `offcputime`                      |
| **kernel headers**         | BCC compiles against them at runtime                    |
| **cgroup v2**              | `cpu.stat` lives in the unified hierarchy               |
| **FlameGraph scripts**     | `flamegraph.pl`, for the SVG                            |
| **Go toolchain**           | `go tool pprof`                                         |

`make investigate` checks all of these before it starts and prints the install
command for whatever is missing.

### macOS cannot run the eBPF step, and the reason is specific

Docker Desktop's linuxkit VM ships BTF (`/sys/kernel/btf/vmlinux`, 6,237,255
bytes) but **no kernel headers** — there is no `/lib/modules/$(uname -r)/build`
and no `CONFIG_IKHEADERS`. BCC compiles its programs against headers at runtime,
so `offcputime-bpfcc` fails there with a `chdir` error. Verified, not assumed.

Use a Linux VM:

```bash
limactl start --name=ebpf template://ubuntu-lts
limactl shell ebpf
sudo apt-get install -y bpfcc-tools linux-headers-$(uname -r) docker.io
git clone https://github.com/brendangregg/FlameGraph ~/FlameGraph
export FLAMEGRAPH_DIR=~/FlameGraph
```

`FLAMEGRAPH_DIR=/path/to/FlameGraph make investigate` is also honoured, as is a
repository-local `tools/FlameGraph/`.

## Honest limitations of the off-CPU step

**The flame graph does not by itself prove cgroup throttling.** Depending on the
kernel, the scheduler, the cgroup configuration, Go's stack unwinding and the BCC
version, throttled intervals may not produce a clean application-level stack. Go
also multiplexes goroutines onto OS threads, so the stacks are per-thread and
cannot tell you which request waited.

If `offcputime` does not resolve useful Go user-space frames in your environment,
the script says so and keeps the kernel and runtime frames as they came. It does
not synthesize an ideal result. `cpu.stat` is unaffected either way — it is a file
read, and it is the step that actually identifies the cause.

## Layout

| Component    | Port | Endpoints                                                     |
|--------------|------|---------------------------------------------------------------|
| service      | 8083 | `POST /compute`, `GET /compute`, `/stats`, `/throttle`, `/reset`, `/healthz` |
| diagnostics  | 6063 | `/debug/pprof/*`                                              |

```
cmd/service          the HTTP service. No -mode flag: there is nothing to switch.
internal/hash        Compute() and ComputeJobs() — deterministic SHA-256
internal/cgroup      parse cpu.max and cpu.stat; delta two readings
scripts/demo4.sh     the before/investigate/after driver
Dockerfile           one image, built once, used by both modes
docker-compose.yml   two profiles and two quotas over that one image
```

## Artifacts

`make investigate` writes the first four to `../artifacts/demo4/`; `make after`
writes the last one, because that is the step that reads it:

```
cpu.pb.gz        the CPU profile
cpu-top.txt      go tool pprof -top output
offcpu.folded    folded off-CPU stacks from offcputime -f
offcpu.svg       the off-CPU flame graph
cpu-stat.txt     the raw cgroup cpu.stat
```

Repeated runs overwrite them cleanly. `cpu.pb.gz`, `offcpu.folded` and
`offcpu.svg` are gitignored — machine-specific and Go-version-specific, and a
stale one invites you to explain numbers your code no longer produces.
`cpu-top.txt`, `cpu-stat.txt` and the committed
[`offcpu-summary.md`](../artifacts/demo4/offcpu-summary.md) are the fallback for a
machine that cannot run the capture at all.

## Configuration

| Variable          | Default | Meaning                                     |
|-------------------|---------|---------------------------------------------|
| `JOBS`            | `16`    | jobs in the request body                    |
| `CAPTURE_SECS`    | `10`    | profile and off-CPU capture window          |
| `APP_PORT`        | `8083`  | application port                            |
| `DIAG_PORT`       | `6063`  | pprof port                                  |
| `FLAMEGRAPH_DIR`  | —       | where to find `flamegraph.pl`               |

Both captures run over the same window, and the request is reissued for the
length of it — a profile of an idle process is empty, and off-CPU stacks of an
idle process are the runtime's own idle loop.

**Docker Desktop's own CPU allocation matters.** The corrected mode asks for 3
cores, so the VM must have at least that (Settings → Resources → CPUs). With
fewer, it throttles too and the fix does not look like a fix.

A period or two still ending throttled on the corrected side is normal: the
request offers 16 runnable goroutines against 3 cores, so it runs the quota flat
out for ~0.4 s, and a period that also carries the GC or straddles a boundary
clips. **The delta is the reading** — ~70 of ~70 against 0 of 5 — and the target
for a real quota is a small ratio, not zero. Chasing zero is how you end up with
no quota at all, which is the answer this demo argues against.

## Other targets

```bash
make status    # ports and the staged mode
make logs      # the staged container's logs
make bench     # per-job CPU cost, no Docker needed
make test      # the equivalence tests, under -race
make clean     # remove containers and artifacts
```

`make bench` is the offline fallback: it measures the per-job CPU cost, which is
precisely the number a correct quota has to be large enough to serve.
