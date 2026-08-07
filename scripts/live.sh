#!/usr/bin/env bash
# Run one live demo script.
#
# Every selector is <demo>-<act>-<name>, so the acts of a demo sort into the order
# they are meant to run in -- both here and in `ls scripts/`.
#
#   ./scripts/live.sh 1-1-load     one request, then the waterfall in Jaeger
#   ./scripts/live.sh 1-2-fix      the diff, the same request, the new waterfall
#   ./scripts/live.sh 2-1-metric   the gauge climbs, and that is all it can say
#   ./scripts/live.sh 2-2-pprof    add pprof, the same load, read the stack
#   ./scripts/live.sh 2-3-fix      the diff, the same load, the same profile
#   ./scripts/live.sh 3-1-metrics  part 1: check pprof
#   ./scripts/live.sh 3-2-trace    part 2: check mutex profile and traces
#   ./scripts/live.sh 3-3-fix      part 3: implement the fix
#   ./scripts/live.sh 4-1-request  part 1: one request, timed
#   ./scripts/live.sh 4-2-pprof    part 2: the CPU profile, and the window it misses
#   ./scripts/live.sh 4-3-ebpf     part 3: off-CPU time, from the kernel
#   ./scripts/live.sh 4-4-cgroup   part 4: the cgroup counters, then a larger quota
#
# The live counterpart of record-cast.sh: the same commands, paced by the speaker
# pressing Enter, with a real browser instead of a recording.
#
# Demo 1 is a pair, and demos 2, 3 and 4 are sequences of three, all meant to be
# run in order with the audience talking in between. Nothing here enforces that:
# the scripts leave their processes running so the next one continues from where
# the last one stopped.
#
# Demo 4's part 2 needs Linux and root, because it loads an eBPF program. It says
# so and falls back to the committed capture rather than failing; parts 1 and 3
# need only Docker.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

n=${1:-}
[[ -n $n ]] || {
	echo "usage: $0 <selector>    run the acts of a demo in numbered order" >&2
	echo
	echo "  1-1-load    demo 1 act 1: one request to /dashboard, then the trace in Jaeger" >&2
	echo "  1-2-fix     demo 1 act 2: the code change, the same request, the new trace" >&2
	echo "  2-1-metric  demo 2 act 1: go_goroutines climbs, and pprof is not there to ask" >&2
	echo "  2-2-pprof   demo 2 act 2: the instrumentation diff, then the [chan send] stack" >&2
	echo "  2-3-fix     demo 2 act 3: the fix diff, the same load, the profile again" >&2
	echo "  3-1-metrics demo 3 act 1: check pprof" >&2
	echo "  3-2-trace   demo 3 act 2: check mutex profile and traces" >&2
	echo "  3-3-fix     demo 3 act 3: implement the fix" >&2
	echo "  4-1-request demo 4 act 1: one request, timed" >&2
	echo "  4-2-pprof   demo 4 act 2: the CPU profile, and the window it misses" >&2
	echo "  4-3-ebpf    demo 4 act 3: off-CPU time, from the kernel" >&2
	echo "  4-4-cgroup  demo 4 act 4: the cgroup counters, then a larger quota" >&2
	exit 2
}

script=scripts/live-demo$n.sh
[[ -x $script ]] || {
	echo "no such live script: $script" >&2
	exit 1
}

exec "./$script"
