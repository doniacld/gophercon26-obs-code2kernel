#!/usr/bin/env bash
# Shared mechanics for the live demo scripts.
#
# The casts and the live scripts run the same commands; only who sets the pace
# differs. A cast types at a fixed delay and sleeps between steps because nobody
# is there to press a key. Live, the speaker is the clock: every step waits for
# Enter, so a question from the room costs nothing and the terminal never runs
# ahead of the explanation.
#
# cast-lib.sh is sourced for the parts that are identical either way — the
# colours, mark() and codediff() — with its pacing switched off, since a live run
# has no use for simulated typing.

TYPE=0 PAUSE=0
# shellcheck source=cast-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/cast-lib.sh"

# Print a short title for the next command, then wait. Ctrl-C is the normal way out
# of a live demo, and Enter is the only key that advances, so a stray keystroke
# cannot skip a step.
step() {
	printf '\n%s# %s%s\n' "$CYAN" "$1" "$NC"
	printf '%s  [Enter]%s' "$GREY" "$NC"
	read -r _ || {
		printf '\n'
		exit 0
	}
	# Enter echoes its own newline, so the cursor is now one line below the prompt.
	# Go back up and erase, otherwise a grey "[Enter]" stays on the slide under
	# every command for the rest of the demo.
	printf '\033[1A\033[2K\r'
}

# Show the command as if it had been typed, then run it for real.
liverun() {
	local cmd=$1 important=${2:-}
	printf '%s$ %s%s\n' "$GREY" "$NC" "$cmd"
	if [[ -n $important ]]; then
		eval "$cmd" 2>&1 | mark "$important"
	else
		eval "$cmd" 2>&1
	fi
	printf '\n'
}

# Print a URL for the speaker to click. Nothing is opened.
#
# Deliberately not `open`/`xdg-open`: a window appearing by itself takes the
# screen away mid-sentence, lands on whichever display the OS feels like, and may
# restore a stale tab. Clicking the printed link puts that moment where the
# speaker wants it, and the terminal stays the thing being watched until then.
showlink() {
	printf '%s%s%s\n' "$UNDER$CYAN" "$1" "$NC"
}

# Bring up Jaeger and the demo in one state, quietly. $1 is a make target:
# before or after.
#
# Quietly is the point. stage.sh ends by announcing whether the calls are made
# one after another or at the same time, which is the entire answer the audience
# is supposed to find in the waterfall. Setup happens before the first step for
# the same reason: what the audience watches should be the request, not four
# services booting.
prepare() {
	local mode=$1
	printf '%s… starting Jaeger and demo 1 (%s)%s\n' "$GREY" "$mode" "$NC"
	# 2>&1 as well as >/dev/null: docker compose reports container state on stderr,
	# so without it the screen opens with "Container gcdemo-jaeger Running" — noise
	# from a component this demo is not about.
	make -C .. up >/dev/null 2>&1
	make "$mode" >/dev/null 2>&1
	printf '%s… ready%s\n' "$GREY" "$NC"
}
