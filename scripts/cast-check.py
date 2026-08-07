#!/usr/bin/env python3
"""Report what a recorded cast actually contains.

A cast is only useful if it ran the real targets and emphasised the right lines,
so this prints the duration, every command typed, and every highlighted line.
Cheaper to read than watching the recording back.

    ./scripts/cast-check.py casts/demo2.cast
"""

import json
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
HIGHLIGHT = re.compile(r"\x1b\[7m(.*?)\x1b\[0m")


def main(path: str) -> int:
    lines = open(path).read().splitlines()
    header = json.loads(lines[0])

    duration = 0.0
    out = []
    for line in lines[1:]:
        if not line.startswith("["):
            continue
        event = json.loads(line)
        duration += event[0]
        if event[1] == "o":
            out.append(event[2])
    text = "".join(out)

    size = header.get("term", {})
    print(f"{path}  {size.get('cols')}x{size.get('rows')}  {duration:.0f}s")
    print(f"  {header.get('title', '')}")

    commands = re.findall(r"^\$ (.+)$", ANSI.sub("", text), re.M)
    print(f"\ncommands ({len(commands)}):")
    for c in commands:
        print(f"  $ {c}")

    marks = [ANSI.sub("", m).strip() for m in HIGHLIGHT.findall(text)]
    print(f"\nhighlighted ({len(marks)}):")
    for m in marks:
        print(f"  · {m}")

    if not marks:
        print("  WARNING: nothing highlighted — check the patterns")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
