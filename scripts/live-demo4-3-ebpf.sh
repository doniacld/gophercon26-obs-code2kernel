#!/usr/bin/env bash
# Demo 4, act 3 — off-CPU time, from the kernel.
#
# Needs Linux and root: BCC loads an eBPF program against the running kernel.
#
#   ./scripts/live-demo4-3-ebpf.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-04-cpu-quota"
source ../scripts/live-lib.sh
# shellcheck source=demo4-common.sh
source ../scripts/demo4-common.sh

if [[ $(uname -s) != Linux ]]; then
	printf '%sNeeds a Linux kernel to load an eBPF program into; this is %s.%s\n' \
		"$GREY" "$(uname -s)" "$NC"
	exit 1
fi

assert_quota

# Same reason as the CPU profile: an idle process is parked in the runtime's idle loop.
step "Put the request on repeat, in the background"
liverun "$LOAD"

# Every stack the process was on when it stopped running, for 10 s.
step "Trace off-CPU time for that container's process"
liverun "$OFFCPUTIME" || true

# Width is time spent not running.
step "Render those stacks as a flame graph"
liverun "$OFFCPU_FLAME"
[[ -s $OFFCPU_SVG ]] && showlink "file://$OFFCPU_SVG"
