#!/usr/bin/env bash
# Regenerate every capturable artifact into artifacts/.
#
# The binary captures are not committed. Profiles and traces are large,
# machine-specific and Go-version-specific, and a stale one is worse than none: it
# invites you to explain numbers your code no longer produces. This script exists
# so they can be recreated in a couple of minutes instead — the day before the
# talk, on the machine that will be on stage.
#
#   ./scripts/capture-artifacts.sh          # everything runnable here
#   ./scripts/capture-artifacts.sh 2 3      # only demos 2 and 3
#
# One directory per artifact kind, matching the things the talk shows:
#
#   demo1-broken-trace/       waterfall.txt              the staircase, as text
#   demo1-fixed-trace/        waterfall.txt              the same spans, overlapping
#   demo2-goroutine-profile/  goroutine-STAGE.txt        the total, and the leaked stacks
#   demo3-mutex-profile/      mutex-MODE.pb.gz           FIRST REVEAL, + top-MODE.txt
#   demo3-locked-trace/       trace.out, sync-top.txt    SECOND REVEAL
#   demo3-unlocked-trace/     trace.out, sync-top.txt    the same window, unlocked
#   demo4/                    cpu.pb.gz, offcpu.folded   the profile that explains only
#                             offcpu.svg, cpu-stat.txt   part of it, then the missing time
#
# The .txt/.json/.md summaries inside those directories *are* committed: if no
# tool runs on stage, the numbers are still on disk. See .gitignore.
#
# Demo 1's artifact is a trace inside Jaeger, which cannot usefully be saved as a
# file — Jaeger's memory storage dies with the container. `make capture` writes the
# waterfall as text instead, which is the form that survives a restart.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

ARTIFACTS="$ROOT/artifacts"

c_grn=$'\033[1;32m'; c_ylw=$'\033[1;33m'; c_blu=$'\033[1;34m'
c_dim=$'\033[2m';    c_off=$'\033[0m'

hdr()  { printf '\n%s=== %s ===%s\n' "$c_blu" "$*" "$c_off"; }
ok()   { printf '%s ok %s %s\n' "$c_grn" "$c_off" "$*"; }
skip() { printf '%sskip%s %s\n' "$c_ylw" "$c_off" "$*"; }
note() { printf '%s     %s%s\n' "$c_dim" "$*" "$c_off"; }

WANT="${*:-1 2 3 4}"
wanted() { case " $WANT " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

D1=demo-01-otel-sequential-calls
D2=demo-02-goroutine-leak
D3=demo-03-lock-contention
D4=demo-04-cpu-quota

# The seven directories, created up front and each given a .gitkeep, so a fresh
# clone shows what a capture produces even before anything has been captured.
for d in demo1-broken-trace demo1-fixed-trace \
         demo2-goroutine-profile \
         demo3-mutex-profile demo3-locked-trace demo3-unlocked-trace \
         demo4; do
  mkdir -p "$ARTIFACTS/$d"
  touch "$ARTIFACTS/$d/.gitkeep"
done

cleanup() {
  for d in "$D1" "$D2" "$D3" "$D4"; do
    make -s -C "$d" down >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

# report DIR NAME — announce a file that was written, with its size.
report() {
  local f="$ARTIFACTS/$1/$2"
  [ -s "$f" ] && ok "$1/$2 ($(du -h "$f" | cut -f1 | tr -d ' '))"
}

# The rehearsal record. Written as we go so a crash halfway still leaves the
# numbers that were captured before it.
REC="$ARTIFACTS/REHEARSAL.md"
{
  echo "# Rehearsal record"
  echo
  echo "Captured on \`$(uname -s) $(uname -r)\`, $(uname -m), Go $(go env GOVERSION)."
  echo "CPUs: $(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '?')."
  echo
  echo "These are the numbers *this* machine produced. If they differ noticeably"
  echo "from the READMEs, trust these and update your talk track — or find out why."
  echo
} > "$REC"

say() { printf '%s\n' "$*" >> "$REC"; }

# --- demo 1 -----------------------------------------------------------------

if wanted 1; then
  hdr "demo 1 — trace waterfalls"
  if ! curl -s -o /dev/null --max-time 2 "http://localhost:${JAEGER_UI_PORT:-16686}/api/services"; then
    skip "Jaeger not up — 'make up' first"
    say "## Demo 1"; say; say "Skipped: Jaeger was not running."; say
  else
    say "## Demo 1 — OTel: independent calls made sequentially"; say
    for mode in broken fixed; do
      make -s -C "$D1" "$mode" >/dev/null 2>&1
      load="$(make -s -C "$D1" load 2>&1 | grep -E 'p50|throughput')"
      # `make capture` labels by the mode stage.sh recorded, so it cannot write a
      # broken-labelled waterfall from a fixed build.
      make -s -C "$D1" capture >/dev/null 2>&1
      report "demo1-$mode-trace" waterfall.txt

      say "**$mode**"; say '```'; say "$load"; say '```'
      if [ -s "$ARTIFACTS/demo1-$mode-trace/waterfall.txt" ]; then
        say; say '```'
        cat "$ARTIFACTS/demo1-$mode-trace/waterfall.txt" >> "$REC"
        say '```'
      fi
      say
    done
    make -s -C "$D1" down >/dev/null 2>&1
  fi
fi

# --- demo 2 -----------------------------------------------------------------
#
# The artifact here is text, not a .pb.gz. Everything the demo shows already comes
# out of /debug/pprof/goroutine as text — the total line and the [chan send]
# stacks — so saving the run's own output is saving the profile. There is nothing
# a `go tool pprof` view would add that the stacks do not already say.

if wanted 2; then
  hdr "demo 2 — the goroutine profile, before and after"
  say "## Demo 2 — pprof: a goroutine leak"; say

  for stage in before after; do
    out="$ARTIFACTS/demo2-goroutine-profile/goroutine-$stage.txt"
    # sed strips the colour: these files are read in a terminal *and* in a diff.
    make -s -C "$D2" "$stage" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$out"
    report demo2-goroutine-profile "goroutine-$stage.txt"

    say "**$stage**"; say '```'
    cat "$out" >> "$REC"
    say '```'; say
  done
  make -s -C "$D2" down >/dev/null 2>&1
fi

# --- demo 3 -----------------------------------------------------------------

if wanted 3; then
  hdr "demo 3 — mutex profiles and execution traces"
  say "## Demo 3 — lock contention: concurrent is not parallel"; say

  for mode in locked unlocked; do
    make -s -C "$D3" "$mode" >/dev/null 2>&1

    # One request is the demo. peak_working and speedup are in the response, so
    # the JSON alone carries the argument if every tool fails.
    one="$(curl -s "http://localhost:8082/compute")"
    say "**$mode**"; say '```'
    printf '%s\n' "$one" | tr ',' '\n' \
      | grep -E 'wall_ms|cpu_time_ms|lock_wait_ms|peak_working|speedup|critical_pct|parallelism' >> "$REC"
    say '```'

    # `make capture` takes the mutex profile, then a SYNC_SECONDS trace, then
    # derives the sync profile from it and writes both text summaries. The long
    # trace is deliberate: a derived profile only counts waits that both start and
    # end inside the window.
    make -s -C "$D3" capture >/dev/null 2>&1
    report demo3-mutex-profile "mutex-$mode.pb.gz"
    report demo3-mutex-profile "top-$mode.txt"
    report "demo3-$mode-trace" trace.out
    report "demo3-$mode-trace" sync-top.txt
    report "demo3-$mode-trace" one-request.json

    if [ -s "$ARTIFACTS/demo3-mutex-profile/top-$mode.txt" ]; then
      say; say "mutex profile:"; say '```'
      head -10 "$ARTIFACTS/demo3-mutex-profile/top-$mode.txt" >> "$REC"
      say '```'
    fi
    if [ -s "$ARTIFACTS/demo3-$mode-trace/sync-top.txt" ]; then
      say; say "blocking profile derived from the trace:"; say '```'
      head -10 "$ARTIFACTS/demo3-$mode-trace/sync-top.txt" >> "$REC"
      say '```'
    fi

    # The CPU profile is captured too, and it is meant to be unhelpful here: the
    # work is genuinely on-CPU, so the profile looks the same in both modes and
    # says nothing about the serialization. Worth having on hand.
    make -s -C "$D3" profile-cpu >/dev/null 2>&1
    report demo3-mutex-profile "cpu-$mode.pb.gz"
    say
  done
  make -s -C "$D3" down >/dev/null 2>&1
fi

# --- demo 4 -----------------------------------------------------------------

if wanted 4; then
  hdr "demo 4 — the missing time: what a CPU profile cannot see"
  say "## Demo 4 — eBPF off-CPU: the elapsed time no CPU profile can see"; say

  # `make before` is one request under the restrictive quota, and its two numbers
  # — the latency and the digest — are the whole record of this half.
  if make -s -C "$D4" before >/tmp/cap4-before.out 2>&1; then
    b_lat="$(grep -oE 'Request latency: .*' /tmp/cap4-before.out | head -1)"
    b_dig="$(grep -oE 'Digest: +[0-9a-f]+' /tmp/cap4-before.out | grep -oE '[0-9a-f]{8,}')"
    ok "before: ${b_lat:-latency not captured}"
    say "**before** (0.25 cores): \`${b_lat:-not captured}\`, digest \`${b_dig:-?}\`"; say
  else
    skip "demo 4 'make before' failed"; tail -5 /tmp/cap4-before.out
    say "before: failed to run."; say
  fi

  # The investigation is one target and writes the four capture artifacts itself,
  # so there is nothing to stitch together here. It needs Linux and root.
  # cpu-stat.txt is not among them: on stage cpu.stat is read by `make after`, so
  # that it confirms the throttling rather than announcing it, and this script
  # captures it from that run below.
  if [ "$(uname -s)" != Linux ]; then
    skip "make investigate needs Linux — see the demo 4 README for the Lima recipe"
    say "Off-CPU capture: skipped, not Linux. BCC needs kernel headers, which Docker"
    say "Desktop's linuxkit VM does not ship."; say
  elif [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    skip "make investigate needs root — run 'make -C $D4 investigate' by hand"
    say "Off-CPU capture: skipped, no root."; say
  else
    make -s -C "$D4" investigate >/tmp/cap4-inv.out 2>&1 || true
    for f in cpu.pb.gz cpu-top.txt offcpu.folded offcpu.svg; do
      report demo4 "$f"
    done

    cpu_hdr="$(grep -E 'Duration|Total samples' "$ARTIFACTS/demo4/cpu-top.txt" 2>/dev/null | head -1)"
    say "CPU profile: \`${cpu_hdr:-not captured}\`"
    note "CPU profile: ${cpu_hdr:-not captured}"

    folded="$ARTIFACTS/demo4/offcpu.folded"
    if [ -s "$folded" ]; then
      stacks="$(wc -l < "$folded" | tr -d ' ')"
      total="$(awk '{s+=$NF} END {printf "%.2f", s/1000000}' "$folded")"
      say "Off-CPU: ${total}s across $stacks stacks"
    fi

    say
  fi

  # `after` opens with cpu.stat for the baseline container and then stages
  # the corrected one, so this one run yields both the confirmation and the fix.
  if make -s -C "$D4" after >/tmp/cap4-after.out 2>&1; then
    report demo4 cpu-stat.txt
    thr="$(grep -E 'nr_periods|nr_throttled|Throttle periods|periods throttled' /tmp/cap4-after.out | head -4)"
    [ -n "$thr" ] && { say '```'; say "$thr"; say '```'; say; }

    f_lat="$(grep -oE 'Request latency: .*' /tmp/cap4-after.out | head -1)"
    f_dig="$(grep -oE 'Digest: +[0-9a-f]+' /tmp/cap4-after.out | grep -oE '[0-9a-f]{8,}')"
    ok "after: ${f_lat:-latency not captured}"
    say "**after** (3 cores): \`${f_lat:-not captured}\`, digest \`${f_dig:-?}\`"
    # The digest is what makes 'faster' mean something: the same answer, computed
    # in less time, rather than less work.
    if [ -n "$b_dig" ] && [ "$b_dig" = "$f_dig" ]; then
      say; say "Identical digest in both runs — the same work, not less of it."
    fi
    say
  else
    skip "demo 4 'make after' failed"; tail -5 /tmp/cap4-after.out
  fi

  make -s -C "$D4" clean >/dev/null 2>&1
fi

# --- summary ----------------------------------------------------------------

hdr "artifacts"
if find "$ARTIFACTS" -type f ! -name .gitkeep | grep -q .; then
  for d in "$ARTIFACTS"/*/; do
    n="$(find "$d" -type f ! -name .gitkeep | wc -l | tr -d ' ')"
    [ "$n" -gt 0 ] && printf '  %-26s %2s files  %s\n' \
      "$(basename "$d")" "$n" "$(du -sh "$d" | cut -f1 | tr -d ' ')"
  done
  printf '\n'
  printf 'total %s in %s\n' "$(du -sh "$ARTIFACTS" | cut -f1 | tr -d ' ')" "$ARTIFACTS"
  note "Binary captures are not committed; the .txt/.json/.md summaries are."
  note "The rehearsal record is $REC; read it before the talk."
else
  skip "nothing captured"
fi
