#!/usr/bin/env bash
# Shared look and feel for the demo screencasts.
#
# Every cast-demoN.sh runs the real make targets from its demo's README and
# nothing else. This file only decides how the screen looks: how a prompt is
# typed, and which lines of real output get emphasised.
#
# highlight() re-prints nothing and invents nothing — it wraps the lines that
# match a pattern in reverse video as they stream past, so the eye lands on the
# number the README asks the audience to read.

BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
GREY=$'\033[90m'
UNDER=$'\033[4m'
NC=$'\033[0m'

# Speaker pacing. Override to re-record faster: TYPE=0 PAUSE=0 ./cast-demo1.sh
TYPE_DELAY=${TYPE:-0.035}
PAUSE_SCALE=${PAUSE:-1}

pause() { [[ $PAUSE_SCALE == 0 ]] || sleep "$(awk "BEGIN{print ${1:-1}*$PAUSE_SCALE}")"; }

banner() {
	printf '%s%s%s\n' "$BOLD" "$1" "$NC"
	printf '%s%s%s\n\n' "$GREY" "$2" "$NC"
	pause 2
}

# A short title for the command on the next line — what it does, not what it will
# show. The reading of the output is the speaker's, out loud.
note() {
	printf '%s# %s%s\n' "$CYAN" "$1" "$NC"
	pause 1.5
}

# Type a shell prompt, then run the command for real. Lines matching $2 are
# emphasised; everything else passes through untouched, colours and all.
run() {
	local cmd=$1 important=${2:-}
	printf '%s$ %s' "$GREY" "$NC"
	local i
	for ((i = 0; i < ${#cmd}; i++)); do
		printf '%s' "${cmd:i:1}"
		[[ $TYPE_DELAY == 0 ]] || sleep "$TYPE_DELAY"
	done
	printf '\n'
	pause 0.4

	if [[ -n $important ]]; then
		eval "$cmd" 2>&1 | mark "$important"
	else
		eval "$cmd" 2>&1
	fi
	printf '\n'
	pause 2
}

# Reverse-video whole lines that match. The tools here already colour their own
# output, and an embedded reset would end the highlight mid-line — so strip the
# line's escapes first and let the highlight be the only styling on it.
mark() {
	awk -v pat="$1" '
		{
			bare = $0
			gsub(/\033\[[0-9;]*m/, "", bare)
			if (bare ~ pat) printf "\033[7m%s\033[0m\n", bare
			else print
		}
		{ fflush() }
	'
}

closing() {
	printf '%s%s%s\n' "$BOLD" "$1" "$NC"
	pause 3
}

# A clickable URL, on its own line, so the speaker can leave the terminal and
# look at the trace in a browser. Underlined rather than reverse-video: every
# terminal turns an underlined http:// into a link, and the audience reads it as
# "go here" instead of "read this number".
link() {
	printf '%s%s%s\n' "$UNDER$CYAN" "$1" "$NC"
	pause 2
}

# Show one function against another as a unified diff, coloured like git.
#
# The two functions are extracted from the real source file by name, so the diff
# on screen cannot drift from the code that just ran. awk brackets on the func
# line and the closing brace in column one, which is all gofmt guarantees and all
# this needs. The match is index(), not a regex: a Go receiver contains ( and *,
# both of which awk would otherwise read as regex syntax.
#
# Both spellings of a declaration are accepted — "func Name(" for a plain function
# and "func (r *T) Name(" for a method — so demo 1 can diff two methods and demo 2
# two package-level functions with the same helper.
codediff() {
	local file=$1 before=$2 after=$3
	local b a
	b=$(mktemp) a=$(mktemp)
	local extract='
		index($0, "func ") == 1 && (index($0, "func " n "(") == 1 || index($0, ") " n "(")) { p = 1 }
		p { print }
		p && /^}/ { exit }
	'
	awk -v n="$before" "$extract" "$file" >"$b"
	awk -v n="$after" "$extract" "$file" >"$a"

	# diff exits 1 when the files differ, which is the whole point of calling it.
	# Under the casts' set -e -o pipefail that would end the recording here, so the
	# expected 1 is absorbed and only a real failure (2) is allowed through.
	{ diff -u --label "$before" --label "$after" "$b" "$a" || [[ $? == 1 ]]; } | awk '
		/^(---|\+\+\+)/ { printf "\033[1m%s\033[0m\n", $0; next }
		/^@@/           { printf "\033[36m%s\033[0m\n",  $0; next }
		/^\+/           { printf "\033[32m%s\033[0m\n",  $0; next }
		/^-/            { printf "\033[31m%s\033[0m\n",  $0; next }
		                { print }
		{ fflush() }
	'
	rm -f "$b" "$a"
	printf '\n'
	pause 3
}
