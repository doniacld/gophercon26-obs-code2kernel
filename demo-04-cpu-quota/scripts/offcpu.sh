#!/usr/bin/env bash
# Summarise offcputime's folded stacks: how much time off CPU, and how it left.
#
#   ./scripts/offcpu.sh [FOLDED]     default ../artifacts/demo4/offcpu.folded
#
# offcputime -f writes one line per unique stack, semicolon-separated frames and a
# microsecond total. The raw file is thousands of lines and cannot be read on a
# slide, so this does the two pieces of arithmetic that matter and prints the
# kernel's own answer verbatim underneath.
#
# Grouping rather than ranking, for two reasons. The runtime's own idle sleeps
# outweigh the request path, so a plain top-N is mostly sysmon; and 16 concurrent
# jobs produce 16 near-identical stacks, so a top-N of those is the same finding
# split sixteen ways. Grouping by the kernel path into schedule() answers the
# question actually being asked: *how* did this code stop running.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

FOLDED="${1:-$(cd .. && pwd)/artifacts/demo4/offcpu.folded}"

if [ ! -s "$FOLDED" ]; then
  echo "no off-CPU capture at $FOLDED" >&2
  echo "run the offcputime line first (needs Linux + root)" >&2
  exit 1
fi

# us_to_s — microseconds as the seconds a slide can carry.
us_to_s() { awk -v u="$1" 'BEGIN{printf "%.2f s", u/1000000}'; }

total=$(awk '{s+=$NF} END {printf "%d", s+0}' "$FOLDED")
stacks=$(wc -l < "$FOLDED" | tr -d ' ')
req_us=$(grep 'hash\.Compute' "$FOLDED" 2>/dev/null | awk '{s+=$NF} END {printf "%d", s+0}')

printf 'off-CPU total       %s across %s unique stacks\n' "$(us_to_s "$total")" "$stacks"

# The split matters more than the total. Most of the raw figure is the runtime's
# own *voluntary* sleeping — sysmon in nanosleep, the signal loop in futex, idle Ps
# parked — and those threads are off CPU because they asked to be. The finding is
# the part inside the request path.
[ "${req_us:-0}" -gt 0 ] &&
  printf 'in the request path %s (hash.Compute)\n' "$(us_to_s "$req_us")"

printf '\nhow the request path left the CPU:\n'
grep 'hash\.Compute' "$FOLDED" 2>/dev/null |
  awk '{
    us = $NF
    # Classify by the kernel path, which is what distinguishes "was preempted"
    # from "blocked on something". An interrupt reaching schedule() with no syscall
    # frame is involuntary preemption; futex and nanosleep are the process asking.
    if ($0 ~ /el0_interrupt|el0t_64_irq|do_notify_resume/) k = "preempted mid-computation (interrupt, no syscall)"
    else if ($0 ~ /futex/)                                 k = "futex wait (runtime synchronization)"
    else if ($0 ~ /nanosleep/)                             k = "voluntary sleep"
    else if ($0 ~ /el0_svc|invoke_syscall/)                k = "other syscall"
    else                                                   k = "other"
    t[k] += us; n[k]++
  }
  END { for (k in t) printf "%d\t%d\t%s\n", t[k], n[k], k }' |
  sort -rn |
  while IFS=$'\t' read -r us count kind; do
    printf '  %10s  %-48s %s stacks\n' "$(us_to_s "$us")" "$kind" "$count"
  done

# One representative stack, verbatim. The grouping above is this script's
# arithmetic; this is the kernel's own answer, and it is what makes "no syscall in
# the path" checkable rather than asserted.
sample=$(grep 'hash\.Compute' "$FOLDED" 2>/dev/null |
           sort -t' ' -k2 -rn | head -1 | awk '{$NF=""; print $0}')
if [ -n "$sample" ]; then
  printf '\ndeepest stack, as captured:\n'
  tr ';' '\n' <<<"$sample" | sed 's/^/  /' | tail -12
fi
