#!/usr/bin/env bash
# Run every demo end to end and check it still produces the claim its README makes.
#
# This is the pre-conference check. It answers one question: on *this* machine,
# right now, does each demo still show what the talk says it shows? A demo that no
# longer reproduces its own evidence is worse than no demo.
#
#   ./scripts/rehearse.sh            # everything runnable here
#   ./scripts/rehearse.sh 2 3        # only demos 2 and 3
#
# Takes about three minutes. Starts Jaeger itself if demo 1 needs it, and skips
# demo 4's eBPF capture unless Linux and root are available. Skips are reported,
# never hidden: a skip is a demo this machine has not proven.
#
# What it asserts is deliberately clock-independent wherever a clock-independent
# statement of the bug exists, because a rehearsal on a loaded laptop must not
# fail for being slow:
#
#   demo 1   the trace's concurrency factor: sequential vs overlapping
#   demo 2   the go_goroutines gauge's growth, and the [chan send] stack count
#   demo 3   peak_working: 1 task at a time vs many
#   demo 4   peak concurrent blocked calls: unbounded vs the configured bound
#
# Latencies are printed for the talk track, not asserted, except where a demo has
# no counter-based claim to make.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

c_grn=$'\033[1;32m'; c_ylw=$'\033[1;33m'; c_red=$'\033[1;31m'
c_blu=$'\033[1;34m'; c_dim=$'\033[2m';    c_off=$'\033[0m'

hdr()  { printf '\n%s=== %s ===%s\n' "$c_blu" "$*" "$c_off"; }
ok()   { printf '%s ok %s %s\n' "$c_grn" "$c_off" "$*"; PASS=$((PASS + 1)); }
skip() { printf '%sskip%s %s\n' "$c_ylw" "$c_off" "$*"; SKIP=$((SKIP + 1)); }
bad()  { printf '%sFAIL%s %s\n' "$c_red" "$c_off" "$*"; FAIL=$((FAIL + 1)); }
note() { printf '%s     %s%s\n' "$c_dim" "$*" "$c_off"; }

PASS=0; SKIP=0; FAIL=0

WANT="${*:-1 2 3 4}"
wanted() { case " $WANT " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

D1=demo-01-otel-sequential-calls
D2=demo-02-goroutine-leak
D3=demo-03-lock-contention
D4=demo-04-cpu-quota

# Leave nothing running, whatever happens — including on Ctrl-C, which during a
# rehearsal is the most likely way this script ends.
cleanup() {
  for d in "$D1" "$D2" "$D3" "$D4"; do
    make -s -C "$d" down >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

# num FILE PATTERN — pull one number out of captured output, or print '?'.
num() { grep -oE "$2" "$1" 2>/dev/null | head -1 || printf '?'; }

# jnum JSON KEY — pull one numeric JSON field out of a string, or print nothing.
jnum() { printf '%s' "$1" | grep -oE "\"$2\": *[0-9.]+" | head -1 | grep -oE '[0-9.]+$'; }

# gt A B — is A > B, in floating point? Used instead of [ ] so thresholds can be
# fractional without shell arithmetic errors.
gt() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a > b)}'; }

# --- static checks first: cheap, and they gate everything else ---------------

hdr "static"
if gofmt -l . | grep -q .; then bad "gofmt: files need formatting: $(gofmt -l . | tr '\n' ' ')"
else ok "gofmt clean"; fi

if go vet ./... 2>/tmp/rehearse-vet.err; then ok "go vet clean"
else bad "go vet failed"; sed 's/^/     /' /tmp/rehearse-vet.err; fi

if go test -race ./... >/tmp/rehearse-test.out 2>&1; then
  ok "go test -race: $(grep -c '^ok' /tmp/rehearse-test.out) packages"
else
  bad "go test -race failed"; grep -E '^(---|FAIL|\s+---)' /tmp/rehearse-test.out | head -12
fi

for f in scripts/*.sh */stage.sh */scripts/*.sh; do
  bash -n "$f" || bad "$f has a syntax error"
done
ok "shell scripts parse"

# --- demo 1 -----------------------------------------------------------------
#
# The claim: both modes emit exactly the same three child spans, and only their
# arrangement on the timeline changes. dump-trace.py computes a concurrency factor
# from the span timestamps — sum of children over the wall clock they cover — so
# the assertion is on trace *shape*, not on latency.

if wanted 1; then
  hdr "demo 1 — OTel: independent calls made sequentially"
  jaeger_up() {
    curl -s -o /dev/null --max-time 2 "http://localhost:${JAEGER_UI_PORT:-16686}/api/services"
  }
  # Start Jaeger rather than skipping. A rehearsal already starts and stops four
  # demo services, and `make up` is one docker command away — skipping the one demo
  # whose dependency this repository can start itself would make `make clean &&
  # make rehearse` silently prove less than it appears to. Only skip if Docker
  # cannot provide it, which is a genuine environment limit.
  if ! jaeger_up; then
    note "Jaeger is not up — starting it ('make up')"
    make -s -C "$ROOT" up >/tmp/r1-jaeger.out 2>&1 || true
  fi
  if ! jaeger_up; then
    skip "Jaeger did not come up — see /tmp/r1-jaeger.out"
    note "This is the only demo with an external dependency; Docker must be running."
  else
    if make -s -C "$D1" broken >/tmp/r1.out 2>&1; then
      make -s -C "$D1" load >/tmp/r1-load.out 2>&1
      b_p50="$(num /tmp/r1-load.out 'p50=[0-9.]+m?s')"
      b_rps="$(num /tmp/r1-load.out 'throughput [0-9.]+')"
      make -s -C "$D1" trace >/tmp/r1-trace.out 2>&1
      b_factor="$(num /tmp/r1-trace.out 'concurrency factor +[0-9.]+' | grep -oE '[0-9.]+$')"
      b_spans="$(num /tmp/r1-trace.out '\([0-9]+ children\)' | grep -oE '[0-9]+')"

      if grep -q 'sequential — a staircase' /tmp/r1-trace.out; then
        ok "broken: $b_p50, concurrency factor ${b_factor:-?} — the waterfall is a staircase"
      else
        bad "broken: the waterfall does not report a sequential shape (factor ${b_factor:-?})"
        note "check 'make demo1-trace' by hand — Jaeger may have returned a partial trace"
      fi

      make -s -C "$D1" fixed >/tmp/r1f.out 2>&1
      make -s -C "$D1" load >/tmp/r1f-load.out 2>&1
      f_p50="$(num /tmp/r1f-load.out 'p50=[0-9.]+m?s')"
      f_rps="$(num /tmp/r1f-load.out 'throughput [0-9.]+')"
      make -s -C "$D1" trace >/tmp/r1f-trace.out 2>&1
      f_factor="$(num /tmp/r1f-trace.out 'concurrency factor +[0-9.]+' | grep -oE '[0-9.]+$')"
      f_spans="$(num /tmp/r1f-trace.out '\([0-9]+ children\)' | grep -oE '[0-9]+')"

      if grep -q 'overlapping' /tmp/r1f-trace.out; then
        ok "fixed: $f_p50, concurrency factor ${f_factor:-?} — the same spans, overlapping"
      else
        bad "fixed: the waterfall still reports a sequential shape (factor ${f_factor:-?})"
      fi

      # The line the talk actually turns on: identical instrumentation, different
      # control flow. If the child counts differ, the demo is making a different
      # point from the one on the slide.
      if [ -n "$b_spans" ] && [ "$b_spans" = "${f_spans:-}" ]; then
        ok "both modes emitted the same $b_spans child spans — only the arrangement changed"
      else
        bad "child span counts differ: broken ${b_spans:-?}, fixed ${f_spans:-?} — the modes are not comparable"
      fi
      note "$b_p50 / $b_rps req/s  ->  $f_p50 / $f_rps req/s"
      make -s -C "$D1" down >/dev/null 2>&1
    else
      bad "demo 1 failed to start"; tail -8 /tmp/r1.out
    fi
  fi
fi

# --- demo 2 -----------------------------------------------------------------
#
# The claim, in two halves, because the demo makes it with two tools: the
# go_goroutines gauge on /metrics detects that goroutines are accumulating, and the
# goroutine profile diagnoses what they are stuck on. Both targets print the gauge
# before and after the requests, so the assertion is on a real Prometheus scrape and
# on real profile output — nothing here is counted by the server itself.
#
# The absolute gauge values are machine- and version-dependent (the HTTP server,
# the metrics handler and the profiler all have goroutines of their own), so the
# assertions are on *growth*. The 100 leaked stacks are exact: one per request.

if wanted 2; then
  hdr "demo 2 — go_goroutines detects it, pprof diagnoses it"

  # gauges FILE — the two go_goroutines values the run scraped, before and after.
  gauges() { awk '$1 == "go_goroutines" { print $2 }' "$1"; }

  if make -s -C "$D2" before >/tmp/r2.out 2>&1; then
    b_before="$(gauges /tmp/r2.out | head -1)"
    b_after="$(gauges /tmp/r2.out | tail -1)"
    b_leaked="$(num /tmp/r2.out '[0-9]+ goroutines blocked on channel send' | grep -oE '^[0-9]+')"

    if make -s -C "$D2" after >/tmp/r2f.out 2>&1; then
      f_before="$(gauges /tmp/r2f.out | head -1)"
      f_after="$(gauges /tmp/r2f.out | tail -1)"

      note "before  go_goroutines ${b_before:-?} -> ${b_after:-?}, ${b_leaked:-0} blocked in [chan send]"
      note "after   go_goroutines ${f_before:-?} -> ${f_after:-?}, none blocked in [chan send]"

      # Detection: the gauge has to be the thing that would have alerted. If it did
      # not move, the demo has no first act.
      if [ -n "$b_before" ] && [ -n "$b_after" ] && [ "$b_after" -gt "$(( b_before + 50 ))" ]; then
        ok "DETECTION: go_goroutines grew and stayed: ${b_before} -> ${b_after}"
      else
        bad "go_goroutines did not grow (${b_before:-?} -> ${b_after:-?}) — is /metrics answering?"
        tail -8 /tmp/r2.out
      fi

      # Diagnosis: 100 requests are sent, so ~100 stacks. Requiring at least half
      # keeps this honest on a loaded rehearsal box without letting a blip pass.
      if [ "${b_leaked:-0}" -ge 50 ]; then
        ok "DIAGNOSIS: the profile names ${b_leaked} goroutines in [chan send]"
      else
        bad "only ${b_leaked:-0} goroutines leaked — expected ~100"
        tail -8 /tmp/r2.out
      fi
      if grep -q 'main.handleWorkBroken' /tmp/r2.out; then
        ok "the stack names this program's own function, not a runtime frame"
      else
        bad "the profile excerpt does not name main.handleWorkBroken"
      fi

      # The fix: the identical requests, and the gauge comes back. A couple of
      # goroutines of slack covers a connection still closing.
      if [ -n "$f_before" ] && [ -n "$f_after" ] && [ "$f_after" -le "$(( f_before + 5 ))" ]; then
        ok "the fix leaves nothing behind: go_goroutines ${f_before} -> ${f_after}"
      else
        bad "the fixed version still gained goroutines (${f_before:-?} -> ${f_after:-?})"
        tail -8 /tmp/r2f.out
      fi
      if grep -q 'no accumulated application goroutines' /tmp/r2f.out; then
        ok "no repeated application stack left blocked on a channel send"
      else
        bad "the fixed run still reports goroutines blocked on channel send"
      fi
    else
      bad "demo 2 fixed mode failed"; tail -8 /tmp/r2f.out
    fi
    make -s -C "$D2" down >/dev/null 2>&1
  else
    bad "demo 2 failed to start"; tail -8 /tmp/r2.out
  fi
fi

# --- demo 3 -----------------------------------------------------------------
#
# The claim: sixteen tasks that could run at once run strictly one at a time. The
# machine-independent form of that is peak_working — 1 versus 16 — because the
# speedup is bounded by GOMAXPROCS and a 4-core rehearsal box cannot show 15x.

if wanted 3; then
  hdr "demo 3 — lock contention: concurrent is not parallel"
  if make -s -C "$D3" locked >/tmp/r3.out 2>&1; then
    b="$(curl -s "http://localhost:8082/compute")"
    b_wall="$(jnum "$b" wall_ms)"
    b_sp="$(jnum "$b" speedup)"
    b_peak="$(jnum "$b" peak_working)"
    b_crit="$(jnum "$b" critical_pct)"
    nproc="$(jnum "$b" gomaxprocs)"

    make -s -C "$D3" unlocked >/dev/null 2>&1
    f="$(curl -s "http://localhost:8082/compute")"
    f_wall="$(jnum "$f" wall_ms)"
    f_sp="$(jnum "$f" speedup)"
    f_peak="$(jnum "$f" peak_working)"
    f_crit="$(jnum "$f" critical_pct)"

    note "locked ${b_wall:-?}ms speedup ${b_sp:-?} peak_working ${b_peak:-?} critical ${b_crit:-?}%"
    note "unlocked ${f_wall:-?}ms speedup ${f_sp:-?} peak_working ${f_peak:-?} critical ${f_crit:-?}%"

    # peak_working needs no clock: 1 means the tasks were serialized, whatever the
    # machine. This is the assertion that survives a loaded CI box.
    if [ "${b_peak:-0}" = "1" ]; then
      ok "locked: peak_working 1 — one task computing at a time on ${nproc:-?} processors"
    else
      bad "locked: peak_working is ${b_peak:-?}, expected 1 — the lock is not serializing the work"
    fi
    if gt "${f_peak:-0}" 1; then
      ok "unlocked: peak_working ${f_peak} — the same work, in parallel"
    else
      bad "unlocked: peak_working is still ${f_peak:-?} — the fix is not taking effect"
    fi
    if gt 1.5 "${b_sp:-0}" && gt "${f_sp:-0}" 2.5; then
      ok "speedup ${b_sp} -> ${f_sp} (GOMAXPROCS=${nproc:-?}) as the README claims"
    else
      bad "speedup ${b_sp:-?} -> ${f_sp:-?} does not match the README; GOMAXPROCS=${nproc:-?}"
      note "on fewer than 4 processors expect a smaller ratio — peak_working is the claim that holds"
    fi

    # The two reveals, in the order the talk uses them. Re-stage locked first: the
    # comparison above left the service in unlocked mode, where there is no
    # contention to find. Capturing here and looking for Mutex.Lock would fail for
    # the most misleading possible reason — the demo working.
    # The mutex profile attributes contention delay to Unlock, not to Lock: the
    # runtime charges the wait at the moment the holder releases and hands it on.
    # The derived sync profile below is the one that names Lock, and the two
    # together are why this demo has two reveals rather than one.
    make -s -C "$D3" locked >/dev/null 2>&1
    if make -s -C "$D3" profile-mutex >/tmp/r3-mutex.out 2>&1 && \
       grep -q 'sync.(\*Mutex).Unlock' /tmp/r3-mutex.out; then
      delay="$(grep -oE 'accounting for [0-9.]+m?i?n?u?s' /tmp/r3-mutex.out | head -1 | sed 's/accounting for //')"
      ok "FIRST REVEAL: the mutex profile names sync.(*Mutex).Unlock (${delay:-?} of contention delay)"
    else
      bad "the mutex profile does not show sync.(*Mutex).Unlock"
      note "runtime.SetMutexProfileFraction must be set — the service logs it at startup"
      tail -6 /tmp/r3-mutex.out
    fi

    if make -s -C "$D3" trace >/tmp/r3-trace.out 2>&1; then
      if make -s -C "$D3" sync-long 2>/dev/null | grep -q 'sync.(\*Mutex).Lock'; then
        ok "SECOND REVEAL: trace captured in locked mode, its sync profile names the mutex"
      else
        bad "trace captured but the derived sync profile does not show Mutex.Lock"
        note "a derived profile only counts waits that start AND end inside the window;"
        note "SYNC_SECONDS must exceed the longest wait — see $D3/Makefile"
      fi
    else
      bad "trace capture failed"; tail -6 /tmp/r3-trace.out
    fi
    make -s -C "$D3" down >/dev/null 2>&1
  else
    bad "demo 3 failed to start"; tail -8 /tmp/r3.out
  fi
fi

# --- demo 4 -----------------------------------------------------------------
#
# The claim: a request costing ~1.2 core-seconds takes seconds of wall clock, the
# CPU profile accounts for only a fraction of that elapsed time, and the cgroup
# counters name the cause. The clock-independent assertion is nr_throttled against
# nr_periods — it does not depend on how fast this machine is.
#
# The off-CPU capture needs Linux and root, so it is checked but skipped
# elsewhere. cpu.stat is the step that identifies the cause and it needs neither.

if wanted 4; then
  hdr "demo 4 — the missing time: what a CPU profile cannot see"
  # 'Request latency: 7.06 s' or 'Request latency: 404 ms' -> milliseconds. The
  # script prints whichever unit reads better, so comparing the bare numbers would
  # invert the result: 404 is not slower than 7.06.
  #
  # grep -oE rather than sed: BSD sed has no \| alternation, so a sed version of
  # this silently matches nothing on macOS — which is the machine this rehearses on.
  lat_ms() {
    grep -oE 'Request latency: +[0-9.]+ +(ms|s)' "$1" | head -1 |
      awk '{ printf "%.0f", ($4 == "ms") ? $3 : $3 * 1000 }'
  }

  if make -s -C "$D4" before >/tmp/r4.out 2>&1; then
    b_ms="$(lat_ms /tmp/r4.out)"
    b_digest="$(grep -oE 'Digest: +[0-9a-f]+' /tmp/r4.out | grep -oE '[0-9a-f]{8,}')"

    if [ "${b_ms:-0}" -gt 0 ]; then
      ok "throttled request latency: ${b_ms}ms for ~1.17 core-seconds of work"
    else
      bad "could not read the request latency from 'make before'"
    fi

    # The reveal, and it needs no privileges: the kernel's own counters, delta'd
    # over the run that just happened.
    thr="$(curl -s http://localhost:8083/throttle)"
    t_per="$(jnum "$thr" nr_periods)"
    t_thr="$(jnum "$thr" nr_throttled)"
    if [ "${t_per:-0}" -gt 0 ] && [ "${t_thr:-0}" -gt 0 ]; then
      ok "cpu.stat: throttled in ${t_thr} of ${t_per} enforcement periods"
    else
      bad "cpu.stat shows no throttling (${t_thr:-?}/${t_per:-?}) — the quota may not be applied"
      note "check: docker exec gcdemo-demo4-baseline cat /sys/fs/cgroup/cpu.max"
    fi

    # The fix, and the digest that proves it is the same work.
    if make -s -C "$D4" after >/tmp/r4f.out 2>&1; then
      f_ms="$(lat_ms /tmp/r4f.out)"
      f_digest="$(grep -oE 'Digest: +[0-9a-f]+' /tmp/r4f.out | grep -oE '[0-9a-f]{8,}')"

      if [ "${f_ms:-0}" -gt 0 ] && [ "${b_ms:-0}" -gt "${f_ms}" ]; then
        ok "corrected quota: ${b_ms}ms -> ${f_ms}ms ($(awk -v a="$b_ms" -v b="$f_ms" 'BEGIN{printf "%.1f", a/b}')x)"
      else
        bad "the corrected quota was not faster (${b_ms:-?}ms -> ${f_ms:-?}ms)"
      fi

      # The assertion that makes 'faster' mean something: identical work.
      if [ -n "$b_digest" ] && [ "$b_digest" = "$f_digest" ]; then
        ok "identical digest in both modes ($b_digest) — the same work, not less of it"
      else
        bad "digests differ: '$b_digest' vs '$f_digest' — the two runs did different work"
      fi
    else
      bad "demo 4 'make after' failed"; tail -8 /tmp/r4f.out
    fi

    make -s -C "$D4" clean >/dev/null 2>&1
  else
    bad "demo 4 failed to start"; tail -8 /tmp/r4.out
  fi

  # The eBPF half, which most rehearsals cannot run. cpu.stat above already
  # carried the diagnosis, which is why this is a skip and not a failure.
  if [ "$(uname -s)" != Linux ]; then
    skip "off-CPU capture: needs Linux (this is $(uname -s)) — the demo 4 README has the VM recipe"
    note "BCC needs kernel headers, which Docker Desktop's linuxkit VM does not ship"
  elif [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    skip "off-CPU capture: needs root — run 'make -C $D4 investigate' by hand"
  elif ! command -v offcputime-bpfcc >/dev/null 2>&1 && ! command -v offcputime >/dev/null 2>&1; then
    skip "off-CPU capture: BCC not installed (apt-get install bpfcc-tools)"
  else
    ok "eBPF environment is ready (run 'make -C $D4 investigate' for a real capture)"
  fi
fi

# --- verdict ----------------------------------------------------------------

printf '\n'
printf '%d passed, %d skipped, %d failed\n' "$PASS" "$SKIP" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '%sNot ready.%s Fix the failures above before the talk.\n' "$c_red" "$c_off"
  exit 1
fi
if [ "$SKIP" -gt 0 ]; then
  printf '%sReady, with %d skipped.%s Each skip is a demo you have not proven on this machine.\n' \
    "$c_ylw" "$SKIP" "$c_off"
else
  printf '%sReady.%s Every demo reproduced its evidence here.\n' "$c_grn" "$c_off"
fi
