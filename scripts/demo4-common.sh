#!/usr/bin/env bash
# The commands demo 4's three acts share. Strings, not functions, so liverun prints
# the command the audience is meant to read.
#
# Real commands, not `make` targets. Demo 2 types `curl … | grep go_goroutines` and
# demo 3 types `./scripts/cores.sh`; a target name on screen tells the audience
# nothing they can take home, and this demo has a specific reason to care — the
# whole finding is that the last piece of evidence is a *file*, not a tool. `docker
# exec … cat /sys/fs/cgroup/cpu.stat` says that by itself. `make cgroup` hides it.
#
# The two shell scripts are there for the same reason demo 3 has cores.sh: one is a
# loop that has to run in the background, the other is awk over folded stacks. Both
# are short, both are readable, and both are the command a viewer reruns at home.
#
# Nothing here names the quota. The container, the compose profile and the label
# are all "baseline", which is why `docker compose --profile baseline up -d` is safe
# to type in act 1 — the word "throttled" appears nowhere in this repository's
# demo 4 container names, precisely so these commands can be shown verbatim.

APP=http://localhost:8083
DIAG=http://localhost:6063
CONTAINER=gcdemo-demo4-baseline
CGROUP=/sys/fs/cgroup

# Two forms of the same directory, because they are read by different audiences.
#
# ART is what appears inside a typed command, and it is relative: every act runs
# from demo-04-cpu-quota/, and `-o ../artifacts/demo4/cpu.pb.gz` fits on a slide
# where 90 characters of absolute path does not.
#
# ARTIFACTS is absolute, for the file:// link at the end of act 2 — a projected URL
# reading .../demo-04-cpu-quota/../artifacts/ invites a question about the ../, and
# cd resolves it away.
ART=../artifacts/demo4
ARTIFACTS="$(cd "$PWD/$ART" && pwd)"

# --wait rather than a sleep: under a 0.25-core quota the binary takes visibly
# longer to start answering, so a fixed sleep would flake here and nowhere else.
UP="docker compose --profile baseline up -d --wait"
DOWN="docker compose --profile baseline --profile corrected down"

# `down` first, and it is not defensive tidying — it is required. Both services
# publish :8083 and :6063, so exactly one can run; without the down, compose fails
# with "Bind for 0.0.0.0:6063 failed: port is already allocated" in front of the
# room. One service at a time is also the demo's own constraint: "it got slow" needs
# a single subject answering on a single port.
UP_FIXED="docker compose --profile baseline down &&"
UP_FIXED+=" docker compose --profile corrected up -d --wait"

# One request, timed, body discarded. The only number this act is making is how
# long the caller waited; the reply's nine fields each invite a question that a
# later act answers better, and gomaxprocs on screen this early is a spoiler.
#
# -w for the client-observed time, because the server's own elapsed_ms is the
# handler's view and the complaint that started this was a caller's.
ONE="curl -sS -o /dev/null -X POST $APP/compute -H 'Content-Type: application/json'"
ONE+=" -d '{\"jobs\":16}' -w '  %{time_total}s total\\n'"

# Act 2. Three commands, two of them backgrounded, and the & are the point.
#
# The load has to be running while either profile is taken. Both profiles have to
# cover the *same* seconds, or the comparison is between two different moments and
# the room is right to object — so the pprof capture is backgrounded too, and
# offcputime runs in the foreground alongside it. 25 s of load against two 10 s
# windows leaves room for both to start and finish inside it.
LOAD="./scripts/load.sh 25 &"
PROFILE="curl -sS -o $ART/cpu.pb.gz '$DIAG/debug/pprof/profile?seconds=10' &"
# -top rather than a flame graph, for the header line rather than the ranking:
#
#   Duration: 10.90s, Total samples = 2.39s (21.93%)
#
# That ratio is the finding. A flame graph is a picture of the samples only, so it
# reads 100% sha256 either way and says nothing about the seconds pprof never saw.
# nodecount is small because the profile has six nodes and one of them has all of it.
CPU_TOP="go tool pprof -top -nodecount=5 $ART/cpu.pb.gz"

# The PID has to be the host's, not the container's: inside the container the
# process is pid 1, and only the host number means anything to a tracer on the
# host. -f folds the stacks for flamegraph.pl; --stack-storage-size is raised
# because a Go process parks many threads and the default map silently drops
# stacks once it fills.
OFFCPUTIME="sudo offcputime-bpfcc -f --stack-storage-size 65536"
OFFCPUTIME+=" -p \$(docker inspect -f '{{.State.Pid}}' $CONTAINER)"
OFFCPUTIME+=" 10 > $ART/offcpu.folded"
OFFCPU="./scripts/offcpu.sh"
FLAME="flamegraph.pl --colors=io --countname=us"
FLAME+=" --title='Demo 4 - Off-CPU Time (time NOT running)'"
FLAME+=" $ART/offcpu.folded > $ART/offcpu.svg"

OFFCPU_FLAME="$FLAME"

# Act 3, and the whole point of the demo: the evidence is a file.
#
# docker exec rather than a host path, because it is the one form that works on
# both a Linux host and macOS — where the cgroup lives in a VM the host cannot
# see. Inside the container the runtime maps the cgroup to the root of the mount,
# so this really is the kernel's own file for this container.
QUOTA="docker exec $CONTAINER cat $CGROUP/cpu.max"
QUOTA_FIXED="docker exec gcdemo-demo4-corrected cat $CGROUP/cpu.max"
STAT_FIXED="docker exec gcdemo-demo4-corrected cat $CGROUP/cpu.stat"

# Four of cpu.stat's nine lines, because only four of them move: nr_periods is the
# clock, nr_throttled is the finding, throttled_usec is how long the finding cost,
# and usage_usec is the work actually done. Those last two are the pair that make a
# ratio -- time not allowed to run against time spent running. The rest are all-zero
# on this kernel (core_sched, nr_bursts, burst_usec) or a breakdown of usage_usec
# (user_usec, system_usec) that nothing here reads.
STAT="docker exec $CONTAINER cat $CGROUP/cpu.stat"
STAT+=" | grep -E 'nr_periods|nr_throttled|throttled_usec|usage_usec'"

# The quota is raised on the running container rather than by restarting into the
# `corrected` profile: same process, same pid, so the only thing that changed
# between the two requests is cpu.max. /sys/fs/cgroup is read-only inside the
# container, so `echo > cpu.max` there cannot work.
UPDATE_CPUS="docker update --cpus=2 $CONTAINER"

# Put back afterwards, or the next run of act 1 opens on a fast service with no
# symptom to show.
#
# `docker update` is how it is put back, NOT `docker compose restart`: a restart
# keeps whatever docker update last wrote and does not re-apply the compose file's
# `cpus: "0.25"`. Trusting the restart is what makes act 4 open on 200000 100000 --
# already fixed, nothing to show, and every number in the act meaningless.
RESTORE_CPUS="docker update --cpus=0.25 $CONTAINER"

# Restarted for the counters, which are cumulative since the container started:
# without it the act opens on five-digit totals from previous runs. The quota is
# re-asserted alongside it for the reason above.
RESTART="docker compose --profile baseline restart"

# Every act opens under the 0.25-core quota, silently and off screen.
#
# Required because act 4 ends at 2 cores and stays there -- the fix is its
# conclusion, so it is not undone. Without this, rerunning acts 1-3 after act 4
# shows a fast service with nothing wrong: act 2's header reads
# "Total samples = 19.07s (190.68%)" instead of ~23%, which is the opposite of the
# finding, and act 3's stacks lose the preemption they exist to show.
#
# `docker update`, not `docker compose restart`: a restart keeps whatever update
# last wrote and does not re-apply the compose file's `cpus: "0.25"`.
#
# Off screen deliberately -- a `docker update --cpus=0.25` in front of the room
# announces the answer before act 1 has asked the question.
assert_quota() {
	eval "$RESTORE_CPUS" >/dev/null 2>&1 || true
}

OFFCPU_SVG="$ARTIFACTS/offcpu.svg"
FALLBACK="$ARTIFACTS/offcpu-summary.md"
