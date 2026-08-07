#!/usr/bin/env python3
"""Print a Jaeger trace for a service as a terminal waterfall.

This exists so the demo does not depend on a browser. Reading a trace in the
Jaeger UI on a projector means zooming, scrolling, and hoping the wifi holds;
this prints the same structure as text, and — the part the UI does not do —
computes whether the child spans ran one after another or at the same time.

    python3 scripts/dump-trace.py frontend
    python3 scripts/dump-trace.py frontend --mode broken
    python3 scripts/dump-trace.py frontend --slowest --no-color

Stdlib only, on purpose: no pip install before a talk.
"""

import argparse
import json
import sys
import urllib.parse
import urllib.request


class Palette:
    """ANSI codes, or empty strings when --no-color is given.

    Colour is worth having on stage and actively harmful in a file: escape
    sequences in a committed artifact turn `cat` output into noise and make the
    text unusable in a diff.
    """

    def __init__(self, enabled=True):
        codes = {
            "BOLD": "\033[1m", "DIM": "\033[2m", "RED": "\033[31m",
            "GREEN": "\033[32m", "YELLOW": "\033[33m", "RESET": "\033[0m",
        }
        for name, code in codes.items():
            setattr(self, name, code if enabled else "")


def fetch(jaeger, service, limit, mode):
    params = {"service": service, "limit": str(limit)}
    if mode:
        params["tags"] = json.dumps({"demo.mode": mode})
    url = f"{jaeger}/api/traces?" + urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return json.load(r).get("data", [])
    except Exception as exc:  # noqa: BLE001 - a demo script should explain itself
        sys.exit(
            f"could not query Jaeger at {jaeger}: {exc}\n"
            f"is it running? 'make up' at the repository root starts it."
        )


def root_of(trace):
    roots = [s for s in trace["spans"] if not s.get("references")]
    return roots[0] if roots else None


def children(trace, span):
    return [
        s
        for s in trace["spans"]
        if any(r.get("spanID") == span["spanID"] for r in s.get("references", []))
    ]


ATTRS_OF_INTEREST = (
    "demo.mode",
    "dependency.name",
    "dependency.elapsed_ms",
    "dependency.latency_ms",
    "dashboard.strategy",
    "dashboard.total_ms",
    "dashboard.sum_of_dependency_ms",
    "dashboard.slowest_dependency_ms",
    "http.response.status_code",
)


def tags(span):
    return {
        t["key"]: t["value"]
        for t in span.get("tags", [])
        if t["key"] in ATTRS_OF_INTEREST
    }


def concurrency_factor(spans):
    """Average number of spans in flight while any of them was running.

    sum(durations) / (max_end - min_start).

    1.0 means they never overlapped — a staircase. N means N ran at once. This
    single number is the whole diagnosis of demo 1, and it is derived from span
    timestamps alone, so it works on any trace from any backend.
    """
    if not spans:
        return 0.0, 0, 0
    total = sum(s["duration"] for s in spans)
    start = min(s["startTime"] for s in spans)
    end = max(s["startTime"] + s["duration"] for s in spans)
    covered = end - start
    return (total / covered if covered else 0.0), total, covered


def render(trace, width, p):
    root = root_of(trace)
    if root is None:
        print("trace has no root span (partially exported?)")
        return

    total = root["duration"]
    t0 = root["startTime"]
    print(f"{p.BOLD}trace {trace['traceID']}{p.RESET}  total={total / 1000:.1f}ms  spans={len(trace['spans'])}")
    print()

    def walk(span, depth):
        svc = trace["processes"][span["processID"]]["serviceName"]
        start = span["startTime"] - t0
        # A proportional bar, so overlap is visible as alignment and sequence is
        # visible as a staircase. This is the picture the audience remembers.
        off = int(width * start / total) if total else 0
        length = max(1, int(width * span["duration"] / total)) if total else 1
        bar = " " * off + "#" * min(length, max(1, width - off))
        name = ("  " * depth) + span["operationName"]
        print(f"  {name:<30} {p.DIM}{svc:<23}{p.RESET} {span['duration'] / 1000:8.1f}ms  |{bar}")
        a = tags(span)
        if a:
            print(f"  {' ' * 30} {p.DIM}{'':<23}{p.RESET} {' ' * 10}   {p.DIM}{a}{p.RESET}")
        for kid in sorted(children(trace, span), key=lambda s: s["startTime"]):
            walk(kid, depth + 1)

    walk(root, 0)

    kids = children(trace, root)
    factor, summed, covered = concurrency_factor(kids)
    print()
    print(f"  root span                  {total / 1000:8.1f}ms")
    print(f"  sum of child spans         {summed / 1000:8.1f}ms   ({len(kids)} children)")
    print(f"  wall clock they cover      {covered / 1000:8.1f}ms")

    if factor < 1.3:
        print(f"  {p.RED}concurrency factor            {factor:5.2f}   sequential — a staircase{p.RESET}")
        print()
        print(f"  {p.RED}The children never overlapped. End-to-end latency is their sum.{p.RESET}")
    else:
        print(f"  {p.GREEN}concurrency factor            {factor:5.2f}   overlapping{p.RESET}")
        print()
        print(f"  {p.GREEN}The children ran at the same time. Latency is the slowest one.{p.RESET}")

    # The gap analysis still matters: time in the root that no child accounts for
    # is time the instrumentation does not explain, whatever the shape.
    gap = total - covered
    pct = 100 * gap / total if total else 0
    if pct > 15:
        print()
        print(f"  {p.YELLOW}{pct:.0f}% of the root span ({gap / 1000:.1f}ms) is not covered by any child.{p.RESET}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("service")
    ap.add_argument("--jaeger", default="http://localhost:16686")
    ap.add_argument("--limit", type=int, default=40)
    ap.add_argument("--mode", choices=("broken", "fixed"), help="filter on the demo.mode attribute")
    ap.add_argument("--slowest", action="store_true", help="show the slowest trace instead of the newest")
    ap.add_argument("--width", type=int, default=44, help="waterfall bar width in characters")
    ap.add_argument("--no-color", action="store_true", help="omit ANSI codes, for writing to a file")
    args = ap.parse_args()

    traces = fetch(args.jaeger, args.service, args.limit, args.mode)
    if not traces:
        sys.exit(
            f"no traces for service '{args.service}'"
            + (f" with demo.mode={args.mode}" if args.mode else "")
            + "\ngenerate load first, and allow ~2s for the batch exporter to flush."
        )

    keyed = [(t, root_of(t)) for t in traces]
    keyed = [(t, r) for t, r in keyed if r is not None]
    if not keyed:
        sys.exit("all returned traces are missing their root span; wait a moment and retry")

    if args.slowest:
        trace = max(keyed, key=lambda pair: pair[1]["duration"])[0]
    else:
        trace = max(keyed, key=lambda pair: pair[1]["startTime"])[0]

    render(trace, args.width, Palette(enabled=not args.no_color))


if __name__ == "__main__":
    main()
