# Demo 4 — off-CPU capture, as recorded

The fallback for the step that cannot run on a mac. `cpu.pb.gz`, `offcpu.folded`
and `offcpu.svg` are gitignored (binary and machine-specific); this is the part of
them worth reading, and it survives a laptop swap.

Captured with BCC `offcputime-bpfcc -f -p <pid> --stack-storage-size 65536 10` on:

```
Linux 6.8.0-63-generic aarch64, 4 CPUs, cgroup v2
Lima Ubuntu 24.04 VM, Docker 27, quota 25ms/100ms (0.25 cores)
```

## What the CPU profile said

```
Duration: 10s, Total samples = 2.37s (23.70%)

     2.33s 98.31%  crypto/internal/fips140/sha256.blockSHA2
```

Accurate and unhelpful: 2.37 s of on-CPU samples inside a 10 s window. The profile
answers "where did this process consume CPU?" correctly. It cannot answer where the
rest of the elapsed time went, because a pprof CPU profile is built from `SIGPROF`
signals delivered to threads *on* a CPU.

## What the off-CPU capture said

```
40.74 s off-CPU time across 152 unique stacks
17.33 s of that is inside the request path (hash.Compute)

  how the request path left the CPU:
     ~17.3 s  preempted mid-computation (interrupt, no syscall)   131 stacks
```

The total exceeds wall clock because it is summed across threads, and most of the
remainder is the runtime's own *voluntary* sleeping — sysmon, the signal loop, idle
Ps. The number that matters is the split: nearly all of the request path's off-CPU
time is on stacks that reach `schedule()` through an interrupt with **no syscall in
the path** —

```
ComputeJobs.func1 -> hash.Compute -> sha256.Sum256 -> blockSHA2.abi0
  -> el0t_64_irq -> el0_interrupt -> do_notify_resume -> schedule
```

— which is what "taken off the CPU mid-computation" looks like. These goroutines
did not block on a lock, a channel, a file or a socket. There was nothing to wait
for; they were simply not allowed to continue.

That localizes the wait. It does not prove *why* the CPU was withheld.

## What cpu.stat said

```
usage_usec       6064872
nr_periods       251
nr_throttled     238
throttled_usec   45911073

This window: 131 / 131 periods throttled (100%)
```

Every enforcement period in the capture window ended with runnable work forbidden
to continue. This is the step that names the cause, and it is a file read — no
eBPF, no privileges, no agent.

## Caveats, honestly

- Whether Go user-space frames resolve at all depends on the kernel, the BCC
  version and stack unwinding. They did here. Where they do not, `make investigate`
  keeps the kernel and runtime frames as they came rather than synthesizing a
  nicer-looking result.
- Go multiplexes goroutines onto OS threads, so these stacks are per-thread and
  cannot tell you which request waited.
- `cpu.stat` is cumulative since the container started, which is why the script
  also prints a delta over the capture window. Cumulative here was 238/251;
  the window was 131/131.
