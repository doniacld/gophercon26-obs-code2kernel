#!/usr/bin/env bash
# Demo 4, act 4 — the cgroup counters, then a larger quota.
#
#   ./scripts/live-demo4-4-cgroup.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../demo-04-cpu-quota"
source ../scripts/live-lib.sh
# shellcheck source=demo4-common.sh
source ../scripts/demo4-common.sh

# The three counters that move, read from the same file the act cats -- but quietly,
# so what is on screen stays the kernel's own output and not something a script
# printed. Emitted as one "throttled usec usage" line so a single docker exec is
# enough and the three numbers are from the same instant.
counters_now() {
	docker exec "$CONTAINER" cat "$CGROUP/cpu.stat" | awk '
		/^nr_throttled /   { t = $2 }
		/^throttled_usec / { w = $2 }
		/^usage_usec /     { u = $2 }
		END { print t, w, u }'
}

# One request's worth of movement, as a line the room can read: how many periods the
# kernel cut short, how long that cost, and the ratio of that wait to the CPU time
# the process actually got. Above 1 the container spent longer waiting than running.
delta() {
	local label=$1 t0=$2 w0=$3 u0=$4 t1=$5 w1=$6 u1=$7
	awk -v l="$label" -v dt="$((t1 - t0))" \
		-v dw="$((w1 - w0))" -v du="$((u1 - u0))" 'BEGIN {
		printf "  %-15s nr_throttled +%-4d  throttled %5.2fs  usage %5.2fs  ratio %.2f\n",
			l, dt, dw / 1e6, du / 1e6, du ? dw / du : 0
	}'
}

# Restarted so cpu.stat starts near zero: the file is cumulative since the
# container started, and the numbers on screen are only readable as a delta.
#
# The quota is set explicitly after the restart, not left to the compose file: a
# restart keeps whatever `docker update` last wrote, so without this the act can
# open already fixed -- 200000 100000, no throttling, and nothing to show.
printf '%s… restarting the service%s\n' "$GREY" "$NC"
eval "$RESTART" >/dev/null 2>&1
assert_quota

# The act ends at 2 cores and stays there -- the fix is the conclusion, so it is
# not undone. Every act re-asserts the quota at its own top instead (assert_quota),
# which is what makes a rerun start from the symptom again.

# Cumulative since the container started, which was a moment ago.
step "The kernel's CPU counters for that container"
liverun "$STAT"
read -r t0 w0 u0 < <(counters_now)

# Quota and period, in microseconds.
step "What the container is allowed to use"
liverun "$QUOTA"

step "One request"
liverun "$ONE"

# The difference is that one request.
step "The same counters again"
liverun "$STAT"
read -r t1 w1 u1 < <(counters_now)

# No restart, no new image: the same running container.
step "Raise the limit to 2 cores"
liverun "$UPDATE_CPUS"

step "What it is allowed to use now"
liverun "$QUOTA"

step "The same request"
liverun "$ONE"

step "And the counters"
liverun "$STAT"

# The subtraction, done here rather than left to the room: the counters are
# cumulative, so what matters is how far each one moved across each request, not any
# total on its own.
read -r t2 w2 u2 < <(counters_now)
echo
delta "0.25 cores" "$t0" "$w0" "$u0" "$t1" "$w1" "$u1"
delta "2 cores" "$t1" "$w1" "$u1" "$t2" "$w2" "$u2"
