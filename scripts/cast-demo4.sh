#!/usr/bin/env bash
# Demo 4 screencast — the three commands from demo-04-cpu-quota/README.md, run
# for real, in the order the narrative gives them.
#
# Needs Docker: the subject is a cgroup, and a container is how you get one.
#
# `make investigate` is only recorded on Linux with root. It loads an eBPF program
# and reads another process's stacks, and BCC needs kernel headers that Docker
# Desktop's linuxkit VM does not ship — see the demo 4 README. Elsewhere the cast
# skips it and says so rather than recording a failure.
#
# Nothing before `make after` names the CPU quota, here as on stage. The quota is
# the answer, and a recording that opens with it has nothing left for the profiles
# to find.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-04-cpu-quota"
source ../scripts/cast-lib.sh

clear
banner "Demo 4 — a compute endpoint, and how long one request takes" \
	"16 independent jobs of SHA-256 arithmetic. No lock, no I/O, no sleep."

run "make before" 'Request latency|Digest|core-seconds'
note "The symptom: one request, and it takes seconds — and nothing on screen says why"

if [ "$(uname -s)" = Linux ] && { [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; }; then
	run "make investigate" 'Total samples|off-CPU|preempted|offcpu.svg|Hypothesis'
	note "The CPU profile accounts for a fraction of it; the off-CPU stacks find the rest, and stop at a hypothesis"
else
	note "make investigate needs Linux and root — skipped here. The demo 4 README has the VM recipe."
fi

run "make after" 'nr_throttled|Throttle periods|CPU quota|Request latency|Digest'
note "cpu.stat confirms the throttling and names the quota, then the identical request corrected — same digest, so the work did not change"

closing "A CPU profile only sees work while the process is running. Kernel-level observability helps investigate the missing time."
