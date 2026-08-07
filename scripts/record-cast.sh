#!/usr/bin/env bash
# Record one demo's screencast.
#
#   ./scripts/record-cast.sh 1
#
# Width is per demo, set by the widest line that matters. Demo 1's trace
# waterfall is 114 columns and wrapping it destroys the one thing the demo exists
# to show; demo 4's pprof frames carry a full package path and reach 126.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

n=${1:-}
[[ -n $n ]] || {
	echo "usage: $0 <demo-number>" >&2
	exit 2
}

script=scripts/cast-demo$n.sh
[[ -x $script ]] || {
	echo "no such cast script: $script" >&2
	exit 1
}

command -v asciinema >/dev/null || {
	echo "asciinema not installed: brew install asciinema" >&2
	exit 1
}

case $n in
1)
	title="Demo 1 — OpenTelemetry: independent calls made sequentially"
	size=120x40
	;;
1-load)
	title="Demo 1 — a dashboard endpoint and three services behind it"
	size=120x40
	;;
1-fix)
	title="Demo 1 — the change"
	size=120x40
	;;
2)
	title="Demo 2 — a goroutine leak: detected by a metric, diagnosed by a profile"
	size=120x40
	;;
2-metric)
	title="Demo 2 — a goroutine leak, act 1: the metric"
	size=120x40
	;;
2-pprof)
	title="Demo 2 — act 2: the profile"
	size=120x40
	;;
2-fix)
	title="Demo 2 — act 3: the fix"
	size=120x40
	;;
3)
	title="Demo 3 — lock contention: concurrent is not parallel"
	size=170x40
	;;
4)
	title="Demo 4 — the code is innocent: a CPU quota is the bug"
	size=130x40
	;;
*)
	echo "no cast defined for demo $n" >&2
	exit 1
	;;
esac

mkdir -p casts
asciinema rec --overwrite --window-size "$size" \
	--title "$title" --command "./$script" "casts/demo$n.cast"
