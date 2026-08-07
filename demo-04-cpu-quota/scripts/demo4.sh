#!/usr/bin/env bash
# Demo 4 driver: before / investigate / after.
#
# The narrative this implements, in order:
#
#   1. The request is slow.
#   2. The Go CPU profile explains only a small part of the latency.
#   3. An off-CPU flame graph shows where the process spent time NOT running.
#   4. cpu.stat confirms the container was CPU-throttled.
#
# Nothing about the Go program changes between `before` and `after`. One image,
# one digest, one entrypoint, one request body. The only difference is the cgroup
# CPU quota — which is why nothing before step 4 names it.
#
# The quota is deliberately withheld until step 4. `before` shows a slow request
# and does not say what it is running under; `investigate` gets as far as "the
# process was not running, and it did not block on anything", which is a
# hypothesis about being denied CPU, not a diagnosis. `after` opens by reading
# cpu.stat — the kernel's own counters for that same container — and that is
# where the quota is finally named and the hypothesis either holds or does not.
#
# Usage (via the Makefile, which is the supported entry point):
#   make before        start the service, send one request, print the latency
#   make investigate   CPU profile, then the off-CPU flame graph
#   make after         cpu.stat confirms it, then the same request with the
#                      quota corrected
#   make clean         remove containers and artifacts

cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEMO_DIR="$PWD"
# shellcheck source=../../scripts/lib.sh
source ../scripts/lib.sh

# lib.sh sets -e. Turn it back off deliberately: this script has to inspect the
# exit status of the eBPF capture and carry on with a degraded report rather than
# abort, because cpu.stat — the step that actually identifies the cause — is
# unaffected by offcputime failing. Failures that must stop the demo call die().
set +e
set -uo pipefail

APP_PORT="${APP_PORT:-8083}"
DIAG_PORT="${DIAG_PORT:-6063}"
JOBS="${JOBS:-16}"
CAPTURE_SECS="${CAPTURE_SECS:-10}"
ARTIFACTS="${ARTIFACTS:-$(cd "$DEMO_DIR/.." && pwd)/artifacts/demo4}"
COMPOSE=(docker compose)
MODES=(baseline corrected)

APP="http://localhost:$APP_PORT"
DIAG="http://localhost:$DIAG_PORT"
BODY="{\"jobs\":$JOBS}"

bold=$'\033[1m'; dim=$'\033[2m'; off=$'\033[0m'

# heading prints the banner each step opens with, so the three commands look like
# three parts of one story rather than three unrelated scripts.
heading() { printf '\n%sDEMO 4 — %s%s\n\n' "$bold" "$1" "$off"; }
note()    { printf '%s%s%s\n' "$dim" "$*" "$off"; }

# ---------------------------------------------------------------------------
# Container and cgroup plumbing
# ---------------------------------------------------------------------------

require_docker() {
  require_cmd docker
  docker info >/dev/null 2>&1 ||
    die "Docker is not running. This demo's subject is a cgroup, and a container is
     how you get one. Start Docker and retry."
}

# down_all removes both modes' containers. They publish the same ports, so exactly
# one may run; tearing down both is what makes `after` following `before` safe
# rather than a port conflict.
down_all() {
  local m
  for m in "${MODES[@]}"; do
    "${COMPOSE[@]}" --profile "$m" down --remove-orphans >/dev/null 2>&1 || true
  done
  rm -f "$RUN_DIR/mode"
}

# stage MODE — bring up one mode and wait until it answers.
#
# Asserts that the service answering on the port reports the mode we asked for.
# Both modes run byte-identical code, so a stale container is invisible in the
# output: the only thing that would differ is the latency, which is precisely the
# number being measured.
stage() {
  local mode="$1"
  require_docker
  down_all

  "${COMPOSE[@]}" --profile "$mode" build --quiet >/dev/null 2>&1 ||
    die "image build failed — run 'docker compose --profile $mode build' to see why"
  "${COMPOSE[@]}" --profile "$mode" up -d --wait >/dev/null 2>&1 ||
    die "container did not become healthy — 'docker compose --profile $mode logs' has the reason"

  wait_http "$APP/healthz" 60 >/dev/null || die "service never answered on :$APP_PORT"
  wait_http "$DIAG/debug/pprof/" 30 >/dev/null || die "pprof never came up on :$DIAG_PORT"

  local running
  running=$(curl -fsS "$APP/stats" 2>/dev/null |
    sed -n 's/.*"mode": *"\([^"]*\)".*/\1/p' | head -1)
  [ "$running" = "$mode" ] ||
    die "the service on :$APP_PORT reports mode '$running', not '$mode' — a stale container is answering"

  record_mode "$mode"
}

container_of() { printf 'gcdemo-demo4-%s' "$1"; }

# host_pid MODE — the service's PID in the host's PID namespace.
#
# This is what offcputime needs to be pointed at. Inside the container the
# process is pid 1; from the host it is whatever the runtime assigned, and only
# the host number is meaningful to a tracer running on the host.
host_pid() {
  docker inspect -f '{{.State.Pid}}' "$(container_of "$1")" 2>/dev/null || true
}

# cgroup_path MODE — the container's cgroup directory under /sys/fs/cgroup.
#
# Discovered from the process's own /proc entry rather than hard-coded, because
# the layout differs between Docker, containerd, systemd-cgroup slices and
# Kubernetes. Line format in cgroup v2 is "0::/the/path".
cgroup_path() {
  local pid rel
  pid=$(host_pid "$1")
  [ -n "$pid" ] && [ "$pid" != 0 ] || return 1
  rel=$(sed -n 's/^0:://p' "/proc/$pid/cgroup" 2>/dev/null | head -1)
  [ -n "$rel" ] || return 1
  local path="/sys/fs/cgroup${rel}"
  [ -r "$path/cpu.stat" ] || return 1
  printf '%s' "$path"
}

# read_cpu_stat MODE — cpu.stat for the service, however it can be reached.
#
# Two paths, in order of directness. On a Linux host the file is readable at the
# discovered cgroup path, which is the honest thing to show: it is the kernel's
# own file, at its real location. Failing that (macOS, where the cgroup lives in
# a VM the host cannot see), read the same file from inside the container, where
# the runtime maps the cgroup to the root of the mount.
read_cpu_stat() {
  local mode="$1" path
  if path=$(cgroup_path "$mode"); then
    printf '# %s/cpu.stat\n' "$path"
    cat "$path/cpu.stat"
    return 0
  fi
  if docker exec "$(container_of "$mode")" cat /sys/fs/cgroup/cpu.stat 2>/dev/null; then
    printf '# read from inside %s at /sys/fs/cgroup/cpu.stat\n' "$(container_of "$mode")"
    return 0
  fi
  return 1
}

quota_of() {
  docker exec "$(container_of "$1")" cat /sys/fs/cgroup/cpu.max 2>/dev/null | tr -d '\n'
}

# quota_human RAW — "25000 100000" as the number people reason in.
quota_human() {
  case "$1" in
    max*) printf 'unrestricted' ;;
    "")   printf 'unknown' ;;
    *)    awk '{printf "%g ms / %g ms period (%.2f cores)", $1/1000, $2/1000, $1/$2}' <<<"$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# The request
# ---------------------------------------------------------------------------

# one_request — POST /compute once, printing the client-observed latency.
#
# Timed by curl rather than by the server, so the number includes everything the
# caller waits for. Under a quota the server's own elapsed_ms and curl's
# time_total agree closely, because the wait is inside the handler.
one_request() {
  local out status secs
  out=$(curl -sS -X POST "$APP/compute" \
          -H 'Content-Type: application/json' \
          -d "$BODY" \
          -w '\n%{http_code} %{time_total}' \
          --max-time 180 2>/dev/null) || { printf 'request failed\n'; return 1; }

  status=$(tail -1 <<<"$out" | cut -d' ' -f1)
  secs=$(tail -1 <<<"$out" | cut -d' ' -f2)
  LAST_DIGEST=$(sed -n 's/.*"digest": *"\([^"]*\)".*/\1/p' <<<"$out" | head -1)

  printf '  Request latency: %s\n' "$(awk -v s="$secs" 'BEGIN{
    if (s >= 1) printf "%.2f s", s; else printf "%.0f ms", s*1000 }')"
  printf '  HTTP status:     %s\n' "$status"
  [ -n "$LAST_DIGEST" ] && printf '  Digest:          %s…\n' "$LAST_DIGEST"
  [ "$status" = 200 ]
}

# load_bg — the same request, on repeat, for the length of a capture window.
#
# scripts/load.sh holds the loop, because that is the command the live scripts type
# (`./scripts/load.sh 12 &`) and two copies of it would drift. See that file for
# why the request has to be running while either profile is taken.
load_bg() {
  ./scripts/load.sh "$1" >/dev/null 2>&1 &
  LOAD_PID=$!
}

load_stop() {
  [ -n "${LOAD_PID:-}" ] || return 0
  kill "$LOAD_PID" 2>/dev/null || true
  wait "$LOAD_PID" 2>/dev/null || true
  # curl children outlive the subshell's kill when mid-request.
  pkill -P "$LOAD_PID" 2>/dev/null || true
  LOAD_PID=""
}

# ---------------------------------------------------------------------------
# Dependency checks for the investigate step
# ---------------------------------------------------------------------------

OFFCPUTIME=""
FLAMEGRAPH=""

find_offcputime() {
  local c
  for c in offcputime-bpfcc offcputime /usr/share/bcc/tools/offcputime; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then OFFCPUTIME="$c"; return 0; fi
  done
  return 1
}

find_flamegraph() {
  local c
  for c in "${FLAMEGRAPH_DIR:-}/flamegraph.pl" \
           "$DEMO_DIR/../tools/FlameGraph/flamegraph.pl" \
           flamegraph.pl \
           /usr/share/flamegraph/flamegraph.pl \
           /usr/local/FlameGraph/flamegraph.pl \
           "$HOME/FlameGraph/flamegraph.pl"; do
    case "$c" in /flamegraph.pl) continue ;; esac
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then FLAMEGRAPH="$c"; return 0; fi
  done
  return 1
}

# check_deps fails early and with the install command, rather than half way
# through a capture with a container running and load in flight.
check_deps() {
  require_cmd go curl docker

  # `go` being on PATH is not enough: a distro Go older than this module's `go`
  # directive tries to download a newer toolchain, and in a fresh VM that fails.
  # Finding out from `go tool pprof` after a 10-second capture is a waste of the
  # capture, so ask the cheapest possible question up front.
  go version >/dev/null 2>&1 ||
    die "the go toolchain does not work: $(go version 2>&1 | head -1)

     'go tool pprof' reads the CPU profile, so this step needs a Go new enough
     for this module's go directive. A distro package is often too old — install
     a current tarball from https://go.dev/dl/ and put it first on PATH:

       sudo tar -C /usr/local -xzf go1.26.*.linux-\$(dpkg --print-architecture).tar.gz
       export PATH=/usr/local/go/bin:\$PATH"

  [ "$(uname -s)" = Linux ] || die "the off-CPU capture needs Linux (this is $(uname -s)).

     BCC compiles its programs against the running kernel's headers, and Docker
     Desktop's linuxkit VM ships BTF but no headers — verified: there is no
     /lib/modules/\$(uname -r)/build and no CONFIG_IKHEADERS, so offcputime
     cannot load there. Run this demo on a Linux host, or in a Linux VM:

       limactl start --name=ebpf template://ubuntu-lts
       limactl shell ebpf
       sudo apt-get install -y bpfcc-tools linux-headers-\$(uname -r) docker.io
       git clone https://github.com/brendangregg/FlameGraph ~/FlameGraph
       export FLAMEGRAPH_DIR=~/FlameGraph

     'make before' and 'make after' work anywhere Docker does — it is only the
     eBPF capture that needs a Linux kernel you can load a program into."

  find_offcputime || die "BCC offcputime not found (looked for offcputime-bpfcc and offcputime).

       Ubuntu/Debian:  apt-get install -y bpfcc-tools linux-headers-\$(uname -r)
       Fedora/RHEL:    dnf install -y bcc-tools kernel-devel
       Arch:           pacman -S bcc-tools"

  find_flamegraph || die "flamegraph.pl not found.

     Clone Brendan Gregg's FlameGraph scripts and point the demo at them:

       git clone https://github.com/brendangregg/FlameGraph ~/FlameGraph
       FLAMEGRAPH_DIR=~/FlameGraph make investigate

     Or place them at $DEMO_DIR/../tools/FlameGraph/, which is checked by default."

  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 ||
      die "offcputime needs root (or CAP_BPF + CAP_PERFMON) and sudo is not installed"
    sudo -n true 2>/dev/null ||
      note "offcputime needs root — sudo will prompt for a password."
  fi
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# ---------------------------------------------------------------------------
# The reveals, each as its own command
#
# One command per question, so a live script can type them one at a time with the
# audience talking in between — the same shape as demo 3's `make profile-mutex`
# and `make sync`. These print tool output and nothing else: no headings, no
# commentary, no "next step" line. The reading is the speaker's to do out loud.
#
# `before`, `investigate` and `after` below compose them and add the narration,
# which is what a rehearsal or an unattended capture wants.
# ---------------------------------------------------------------------------

# cmd_up MODE — stage one mode and say so in one line.
#
# The mode name is safe to print now that it is "baseline": it says which of the
# two states is answering without saying why either is fast or slow. That is the
# whole reason the mode is not called "throttled" anywhere, including in
# docker-compose.yml — the live scripts type `docker compose --profile baseline up`
# verbatim, and the profile name is on screen in act 1's first command.
cmd_up() {
  local mode="${1:-baseline}"
  stage "$mode"
  log "demo 4 ready (mode=$mode)"
  printf '     application  %s/compute   %sPOST %s%s\n' "$APP" "$dim" "$BODY" "$off"
  printf '     diagnostics  %s/debug/pprof/\n' "$DIAG"
}

# cmd_request — one request, timed, and nothing else.
#
# The reply body is discarded on purpose. The only number this step is making is
# how long the room waited, and a nine-field JSON blob beside it invites nine
# questions that the later steps answer better. The service still returns the
# full body for anyone who curls it by hand; `make stats` reports gomaxprocs and
# the quota, and `make cgroup` reports the throttling.
cmd_request() {
  [ "$(running_mode none)" != none ] || die "nothing is staged — run 'make up' first"
  curl -sS -o /dev/null -X POST "$APP/compute" \
    -H 'Content-Type: application/json' \
    -d "$BODY" \
    -w '  %{time_total}s total, HTTP %{http_code}\n' \
    --max-time 180
}

# cmd_capture — the dual capture, over one window.
#
# Prints only what it is doing and where the files went. The two profiles are read
# back by cpu-top and offcpu, which is what makes them two steps on stage: the
# capture is plumbing, and the reveals are the demo.
cmd_capture() {
  check_deps

  [ "$(running_mode none)" = baseline ] ||
    die "nothing is staged — run 'make up' first"

  local pid
  pid=$(host_pid baseline)
  [ -n "$pid" ] && [ "$pid" != 0 ] ||
    die "could not find the service's host PID — is the container running?"

  mkdir -p "$ARTIFACTS"
  rm -f "$ARTIFACTS"/cpu.pb.gz "$ARTIFACTS"/cpu-top.txt \
        "$ARTIFACTS"/offcpu.folded "$ARTIFACTS"/offcpu.svg

  printf 'sampling pid %s for %ss (%s CPUs): pprof CPU profile + BCC offcputime\n' \
    "$pid" "$CAPTURE_SECS" "$(nproc 2>/dev/null || echo '?')"

  curl -sS "$APP/reset" >/dev/null 2>&1 || true
  load_bg "$CAPTURE_SECS"
  # Let the load actually get going. A profile that starts before the first
  # request arrives spends its first second sampling an idle process.
  sleep 1

  # Both captures run over the same window, so they describe the same seconds of
  # the same request rather than two different moments.
  curl -sS -o "$ARTIFACTS/cpu.pb.gz" \
    "$DIAG/debug/pprof/profile?seconds=$CAPTURE_SECS" >/dev/null 2>&1 &
  local cpu_job=$!

  # -f folds the stacks, which is the format flamegraph.pl wants.
  # --stack-storage-size is raised because a Go process parks many threads and the
  # default map silently drops stacks once full.
  as_root "$OFFCPUTIME" -f -p "$pid" \
      --stack-storage-size 65536 \
      "$CAPTURE_SECS" > "$ARTIFACTS/offcpu.folded" 2>"$ARTIFACTS/offcpu.err"
  local rc=$?

  wait "$cpu_job" 2>/dev/null || true
  load_stop

  # Keep the stderr file only when it has something to say. An empty offcpu.err in
  # the artifacts directory reads like a failure that did not happen.
  [ -s "$ARTIFACTS/offcpu.err" ] || rm -f "$ARTIFACTS/offcpu.err"

  [ -s "$ARTIFACTS/cpu.pb.gz" ] || die "the CPU profile is empty — is pprof up on :$DIAG_PORT?"
  go tool pprof -top -nodecount=12 "$ARTIFACTS/cpu.pb.gz" \
    > "$ARTIFACTS/cpu-top.txt" 2>&1 ||
    die "go tool pprof could not read the profile"

  if [ "$rc" -ne 0 ] || [ ! -s "$ARTIFACTS/offcpu.folded" ]; then
    warn "offcputime produced no usable output (exit $rc)"
    [ -s "$ARTIFACTS/offcpu.err" ] && sed 's/^/  /' "$ARTIFACTS/offcpu.err" >&2
  fi

  printf '%s/cpu.pb.gz  %s/offcpu.folded\n' "$ARTIFACTS" "$ARTIFACTS"
}

# cmd_cpu_top — the CPU profile, as pprof printed it.
#
# Unedited on purpose, `Duration:` header and all. That header is the finding —
# samples far below wall clock — and paraphrasing it would put the conclusion on
# screen in place of the evidence.
cmd_cpu_top() {
  [ -s "$ARTIFACTS/cpu-top.txt" ] ||
    die "no CPU profile captured yet — run 'make capture' first"
  sed 's|github.com/doniacld/go-observability-demos/demo-04-cpu-quota/||' \
    "$ARTIFACTS/cpu-top.txt" | head -12
}

# cmd_offcpu — the off-CPU stacks, summed and grouped, then the flame graph.
#
# The summary itself lives in scripts/offcpu.sh, because that is what the live
# scripts type: it is the command a viewer can rerun against their own folded file,
# and a wrapper the audience cannot see inside would defeat the point. This adds
# the flame graph, which is a second output rather than a second reading.
cmd_offcpu() {
  [ -s "$ARTIFACTS/offcpu.folded" ] ||
    die "no off-CPU capture available — run 'make capture' first (needs Linux + root)"

  ./scripts/offcpu.sh "$ARTIFACTS/offcpu.folded" || return 1

  # Resolved here rather than relying on check_deps, because this runs as its own
  # command: `make offcpu` reads a file that `make capture` wrote, possibly in a
  # different process, and $FLAMEGRAPH would otherwise still be empty.
  if [ -z "$FLAMEGRAPH" ] && ! find_flamegraph; then
    warn "flamegraph.pl not found — the folded stacks above are still the evidence"
    note "point at it with: FLAMEGRAPH_DIR=~/FlameGraph make offcpu"
    return 0
  fi

  # ASCII only in the title: flamegraph.pl writes bytes through without decoding
  # UTF-8, so an em-dash here renders as mojibake in the SVG.
  if "$FLAMEGRAPH" --colors=io \
       --title="Demo 4 - Off-CPU Time (time NOT running)" \
       --countname=us \
       "$ARTIFACTS/offcpu.folded" > "$ARTIFACTS/offcpu.svg" 2>/dev/null &&
     [ -s "$ARTIFACTS/offcpu.svg" ]; then
    printf '\n%s/offcpu.svg\n' "$ARTIFACTS"
  else
    warn "flamegraph.pl failed — the folded stacks above are still the evidence"
    rm -f "$ARTIFACTS/offcpu.svg"
  fi
}

# cmd_cgroup — cpu.max and cpu.stat for whichever mode is staged, as the kernel
# wrote them.
#
# Raw file contents, comment header included, in the spirit of demo 2 leaving
# `# HELP` and `# TYPE` on screen: the file documents itself, and a reading of it
# is worth more than a paraphrase of it. Typed once against the throttled
# container and once against the corrected one, it is the whole confirmation.
cmd_cgroup() {
  local mode
  mode=$(running_mode none)
  [ "$mode" != none ] || die "nothing is staged — run 'make up' first"

  # One request first, so the counters below describe a window that is mostly the
  # request rather than mostly idle.
  #
  # Without it the file is read however many minutes after the request the speaker
  # got here, and every idle 100 ms period in between counts as a period that was
  # not throttled — which drags the ratio down for a reason that has nothing to do
  # with the bug. An idle process cannot be throttled; only a process with runnable
  # work can be, so the honest denominator is the periods during which there was
  # work. /reset rebases the service's own delta to this request.
  curl -sS "$APP/reset" >/dev/null 2>&1 || true
  curl -sS -X POST "$APP/compute" -H 'Content-Type: application/json' \
    -d "$BODY" --max-time 180 >/dev/null 2>&1 || true

  local path
  if path=$(cgroup_path "$mode"); then
    printf '# %s\n' "$path"
  else
    printf '# inside %s, at /sys/fs/cgroup\n' "$(container_of "$mode")"
  fi

  # cpu.max first: it is two numbers, it is the configuration, and it is what makes
  # the counters below mean something rather than being a wall of integers.
  printf '\n# cpu.max — quota and period, in microseconds\n'
  printf '%s   %s%s%s\n' "$(quota_of "$mode")" "$dim" "$(quota_human "$(quota_of "$mode")")" "$off"

  printf '\n# cpu.stat\n'
  if ! read_cpu_stat "$mode" > "$ARTIFACTS/cpu-stat.txt" 2>/dev/null ||
     ! grep -q nr_periods "$ARTIFACTS/cpu-stat.txt"; then
    warn "cpu.stat could not be read — needs cgroup v2"
    note "check: stat -fc %T /sys/fs/cgroup  (want cgroup2fs)"
    return 1
  fi
  grep -vE '^#' "$ARTIFACTS/cpu-stat.txt"

  # The same counters delta'd over the one request just sent. The file above is
  # cumulative since the container started, so on its own it carries every idle
  # period since; this line belongs to the request the audience just watched.
  local thr dp dt
  thr=$(curl -sS "$APP/throttle" 2>/dev/null)
  dp=$(sed -n 's/.*"nr_periods": *\([0-9]*\).*/\1/p' <<<"$thr" | head -1)
  dt=$(sed -n 's/.*"nr_throttled": *\([0-9]*\).*/\1/p' <<<"$thr" | head -1)
  if [ -n "$dp" ] && [ "${dp:-0}" -gt 0 ]; then
    printf '\n# that one request alone\n'
    printf 'nr_throttled / nr_periods   %s / %s   (%s%%)\n' \
      "${dt:-0}" "$dp" "$(awk -v a="${dt:-0}" -v b="$dp" 'BEGIN{printf "%.0f", 100*a/b}')"
  fi
}

# ---------------------------------------------------------------------------
# before
# ---------------------------------------------------------------------------

cmd_before() {
  heading "BEFORE"
  stage baseline

  # No quota printed here, on purpose. The quota is the answer, and the audience
  # is meant to arrive at it from the profiles: a run that opens with "CPU quota:
  # 25 ms / 100 ms" has already been solved before the first tool is used.
  printf '  Request: POST /compute %s\n\n' "$BODY"

  # One warm-up request, not printed. The first request into a cold container pays
  # for page faults and the runtime's own start-up, and under a quarter of a core
  # that shows up as seconds that have nothing to do with throttling. The measured
  # request below is the one the audience sees.
  curl -sS -X POST "$APP/compute" -H 'Content-Type: application/json' \
    -d "$BODY" --max-time 180 >/dev/null 2>&1 || true
  curl -sS "$APP/reset" >/dev/null 2>&1 || true

  one_request || die "the request did not succeed — 'make logs' has the service's side"

  printf '\n'
  note "  ${JOBS} CPU-bound jobs, ~$(awk -v j="$JOBS" 'BEGIN{printf "%.2f", j*0.073}') core-seconds of arithmetic."
  note "  No lock, no I/O, no downstream call, no sleep."
  printf '\n  Next: %smake investigate%s\n' "$bold" "$off"
}

# ---------------------------------------------------------------------------
# investigate
# ---------------------------------------------------------------------------

cmd_investigate() {
  heading "INVESTIGATION"

  # The same four commands a live script types, run back to back with the
  # narration a rehearsal wants and a stage does not.
  cmd_capture
  printf '\n'

  printf '%sCPU profile — what the process did while it was running%s\n' "$bold" "$off"
  cmd_cpu_top | sed 's/^/  /'

  # The header line is the whole point of this step, and it is the line everybody
  # reads past. pprof's percentage is sample-time over wall-clock, summed across
  # threads, so it exceeds 100% when several threads run at once — and lands far
  # below it when the process is mostly not running.
  local samples duration
  samples=$(sed -n 's/.*Total samples = \([^ ]*\).*/\1/p' "$ARTIFACTS/cpu-top.txt" | head -1)
  duration=$(sed -n 's/^Duration: \([^,]*\),.*/\1/p' "$ARTIFACTS/cpu-top.txt" | head -1)
  printf '\n'
  note "  ${duration:-?} of wall clock, ${samples:-?} of on-CPU samples."
  note "  The sampled work does not add up to the latency. A CPU profile is built"
  note "  from SIGPROF signals delivered to threads ON a CPU, so time the process"
  note "  spent not running cannot appear here at all."

  printf '\n%sOff-CPU stacks — where time accumulated while NOT running%s\n' "$bold" "$off"
  if cmd_offcpu | sed 's/^/  /'; then
    printf '\n'
    # The shape worth pointing at, if it is there. A stack that reaches schedule()
    # through el0_interrupt / do_notify_resume took no syscall to get there: the
    # goroutine did not block on anything, it was taken off the CPU mid-hash. That
    # is what being denied CPU looks like from the inside, as opposed to waiting
    # for I/O — but it still does not say *why*, which is the next step's job.
    if grep -q 'do_notify_resume\|el0_interrupt\|el0t_64_irq' "$ARTIFACTS/offcpu.folded" 2>/dev/null; then
      note "  Note the path into schedule(): no syscall, an interrupt. These goroutines"
      note "  did not block on anything — they were taken off the CPU mid-computation."
    fi
    note "  This says where the time accumulated, not why it was withheld. Whether"
    note "  these resolve to Go frames depends on the kernel, the BCC version and"
    note "  stack unwinding; kernel and runtime frames are kept as they came."
  else
    note "  The cgroup counters in 'make after' are unaffected — they are a plain"
    note "  file read, and they are what actually identifies the cause."
  fi

  # --- artifacts and the hypothesis ---------------------------------------
  #
  # This step stops one inference short of the answer, and that is the shape of
  # the demo. Two facts are on the screen — the process was off CPU for most of
  # the request, and it reached schedule() without a syscall — and together they
  # narrow the cause to "something took the CPU away", not "the code waited".
  # That is a hypothesis. `make after` tests it against the kernel's own counters.
  printf '\n%sArtifacts%s\n' "$bold" "$off"
  local f
  for f in cpu.pb.gz cpu-top.txt offcpu.folded offcpu.svg; do
    [ -s "$ARTIFACTS/$f" ] && printf '  %s\n' "$ARTIFACTS/$f"
  done

  printf '\n%sHypothesis%s\n' "$bold" "$off"
  printf '  The process was runnable and not running: something took the CPU away.\n'
  printf '  Nothing so far proves that, and a flame graph on its own cannot.\n'
  printf '\n  Next: %sopen %s/offcpu.svg%s, then %smake after%s to test it\n' \
    "$bold" "$ARTIFACTS" "$off" "$bold" "$off"
}

# ---------------------------------------------------------------------------
# the cgroup counters — the step that turns the hypothesis into a cause
#
# Deliberately last, and deliberately separate from the eBPF capture. cpu.stat
# names the mechanism outright, so reading it early ends the investigation before
# it starts: the audience would have the answer before seeing why the CPU profile
# could not have given it to them. Run after the off-CPU evidence has raised the
# question, it is a confirmation rather than an announcement.
#
# It must run before `after` stages the corrected container: the counters belong
# to the throttled cgroup, and staging tears that container down.
# ---------------------------------------------------------------------------

cgroup_evidence() {
  printf '%sCgroup CPU statistics — the kernel'"'"'s own accounting%s\n' "$bold" "$off"
  note "  replaying the same request under the current quota, to date the counters…"
  printf '\n'

  cmd_cgroup | sed 's/^/  /' || {
    warn "without cpu.stat this demo has no confirmation step"
    printf '\n'
    return 1
  }

  printf '\n'
  note "  throttled_usec is summed across tasks, so it can exceed wall clock."
  note "  A ratio near 1.0 means nearly every enforcement period ended with"
  note "  runnable work forbidden to continue. No privileges, no agent: a file read."
  printf '\n'
}

# ---------------------------------------------------------------------------
# after
# ---------------------------------------------------------------------------

cmd_after() {
  heading "AFTER"

  # The confirmation first, while the throttled container is still the one running.
  # Reading it here rather than in `investigate` is what keeps the eBPF step an
  # investigation: the flame graph raises the question, this file answers it, and
  # the corrected run below is then a test of the answer rather than a hope.
  require_docker
  if [ "$(running_mode none)" = baseline ]; then
    cgroup_evidence
  else
    note "  (nothing is staged — run 'make before' first to see the counters)"
    printf '\n'
  fi

  printf '%sThe correction: the same quota, sized from that demand%s\n' "$bold" "$off"
  stage corrected

  local raw
  raw=$(quota_of corrected)
  printf '  CPU quota: %s\n' "$(quota_human "$raw")"
  printf '  Request:   POST /compute %s\n\n' "$BODY"

  curl -sS -X POST "$APP/compute" -H 'Content-Type: application/json' \
    -d "$BODY" --max-time 180 >/dev/null 2>&1 || true
  curl -sS "$APP/reset" >/dev/null 2>&1 || true

  one_request || die "the request did not succeed — 'make logs' has the service's side"

  # The counters again, because "throttled in almost no periods" is what makes
  # this the fix rather than merely a faster run.
  #
  # Read from /throttle rather than from cpu.stat directly: the file is cumulative
  # since the container started, so it still carries the warm-up request's
  # throttling and would understate the correction. /throttle reports a delta
  # since the /reset above, so the number belongs to the measured request.
  local thr periods throttled
  thr=$(curl -sS "$APP/throttle" 2>/dev/null)
  periods=$(sed -n 's/.*"nr_periods": *\([0-9]*\).*/\1/p' <<<"$thr" | head -1)
  throttled=$(sed -n 's/.*"nr_throttled": *\([0-9]*\).*/\1/p' <<<"$thr" | head -1)
  if [ -n "$periods" ]; then
    printf '  Throttled:       %s / %s periods\n' "${throttled:-0}" "$periods"
  fi

  # A non-zero count here is residual, not a failed fix, and saying so is cheaper
  # than being asked. The request offers 16 runnable goroutines against 3 cores, so
  # it runs the quota flat out for ~0.4 s: a period that also has to carry the GC,
  # the runtime's own threads or work straddling a period boundary can still end
  # throttled. The ratio is the reading — 133/133 against a couple out of five.
  #
  # This is also the honest version of "size a quota from measured demand": the
  # target is a small ratio, not zero. Chasing zero is how you end up with no quota
  # at all, which is the answer this demo argues against.
  if [ "${throttled:-0}" -gt 0 ] && [ -n "$periods" ]; then
    printf '\n'
    note "  ${throttled}/${periods} is residual, not a failed fix: 16 runnable goroutines"
    note "  against 3 cores runs the quota flat out, so a period carrying the GC or"
    note "  straddling a boundary still clips. Compare the ratio, not the count."
  fi

  printf '\n'
  note "  Same image, same digest, same endpoint, same body, same job count."
  note "  One line of YAML changed: the CPU quota. Not one line of Go."
  note "  And note what this is NOT — the quota was corrected, not removed."
}

# ---------------------------------------------------------------------------

cmd_clean() {
  if docker info >/dev/null 2>&1; then
    down_all
    log "demo 4 containers removed"
  else
    rm -f "$RUN_DIR/mode"
    warn "Docker is not running — nothing to stop"
  fi
  # The generated captures by name, not `rm -rf $ARTIFACTS`. The directory also
  # holds committed fallbacks — offcpu-summary.md and .gitkeep — and removing those
  # would delete the safety net for a machine that cannot run the capture at all,
  # as part of routine cleanup. The root Makefile's clean keeps artifacts/ for the
  # same reason.
  rm -f "$ARTIFACTS"/cpu.pb.gz "$ARTIFACTS"/cpu-top.txt "$ARTIFACTS"/cpu-stat.txt \
        "$ARTIFACTS"/offcpu.folded "$ARTIFACTS"/offcpu.svg "$ARTIFACTS"/offcpu.err
  rm -rf "$DEMO_DIR/bin" "$DEMO_DIR/.run"
  log "generated captures removed (committed fallbacks kept)"
}

cmd_status() {
  printf 'demo 4 ports:\n'
  status "$APP_PORT" "$DIAG_PORT"
  printf '\nstaged mode: %s\n' "$(running_mode none)"
}

case "${1:-}" in
  # The three composite steps: same commands as below, plus the narration.
  before)      cmd_before ;;
  investigate) cmd_investigate ;;
  after)       cmd_after ;;
  # The granular ones a live script types, one question each, output only.
  up)          cmd_up "${2:-baseline}" ;;
  request)     cmd_request ;;
  capture)     cmd_capture ;;
  cpu-top)     cmd_cpu_top ;;
  offcpu)      cmd_offcpu ;;
  cgroup)      cmd_cgroup ;;
  clean)       cmd_clean ;;
  status)      cmd_status ;;
  *) die "usage: $0 {before|investigate|after|up|request|capture|cpu-top|offcpu|cgroup|clean|status}" ;;
esac
