#!/usr/bin/env bash
# The commands demo 2's three acts share, in one place.
#
# Six scripts show these — three casts and their three live twins — and the
# audience is asked to compare their output across acts. A gauge read one way in
# act 1 and another way in act 3 would make that comparison a lie, so the strings
# live here and every act types the identical thing.
#
# They are strings, not functions, because run() and liverun() print the command
# before running it: what appears on the slide has to be the command itself, not
# the name of a wrapper the audience cannot see inside.
#
# Source after cast-lib.sh or live-lib.sh, from within demo-02-goroutine-leak.

APP=http://localhost:8081
DIAG=http://localhost:6061
METRICS="$DIAG/metrics"
PPROF="$DIAG/debug/pprof/goroutine"

# The one line that reads the signal.
#
# grep, not awk: three lines of output instead of one, and the two extra are worth
# the room. Prometheus ships the metric's own documentation next to its value, so
# "Number of goroutines that currently exist" and "gauge" arrive from the exposition
# format rather than from the presenter — including the answer to "is this a
# snapshot or a total?", which is the first thing anyone asks of a climbing number.
GAUGE="curl -s $METRICS | grep go_goroutines"

# 100 requests that every client abandons after 20ms, against work that takes
# 90ms. -P 20 keeps twenty in flight so the batch is over in about a second, and
# `|| true` absorbs the exit code every one of them is supposed to have: curl
# times out on purpose here, and that is the condition the bug needs.
#
# The trailing sleep is not padding. It is longer than the work, so every worker
# has had time to reach whichever fate its version has — parked on the send, or
# returned — before anything is measured. Without it both modes would look clean.
LOAD="seq 1 100 | xargs -P 20 -I{} curl -s -o /dev/null --max-time 0.02 $APP/work || true; sleep 0.3"

# Every goroutine in the process, one line each: its id and its state.
#
# debug=2 rather than debug=1, and it is the difference the demo needs. debug=1
# collapses identical stacks into a "100 @ 0x..." count and drops the state
# entirely; debug=2 dumps every goroutine separately with its state in the header,
# and the state is the whole finding. A count of a hundred says something grew. A
# hundred headers reading [chan send] says what they are all waiting for.
#
# The grep keeps only the header lines, because the stanzas behind them are 689
# lines of frames. What is left is a roll call the room can read down: one
# [running] (the profiler itself), a few [IO wait] (the listeners), and then a
# hundred identical states. Act 3 runs the same line and it fits in five.
PROFILE_LIST="curl -s '$PPROF?debug=2' | grep '^goroutine '"

# How many goroutines are parked on a channel send.
#
# The one number that is directly comparable between act 2 and act 3, which is why
# both of them run this line: 100, and then 0. grep -c exits 1 when it counts
# nothing, and counting nothing is the good outcome here, so the status is dropped.
BLOCKED="curl -s '$PPROF?debug=2' | grep -c 'chan send' || true"

# One goroutine, in full — the state, the function, the line, and its parent.
#
# debug=2 is the only form that prints the state, and "[chan send]" in that header
# is what turns "a hundred goroutines" into "a hundred goroutines parked on a
# channel send". One stanza is enough; the other ninety-nine are identical, which
# is itself the diagnosis.
#
# awk rather than `grep -A4 ... | head -5`: head closing the pipe early sends
# SIGPIPE upstream, and under the casts' `set -o pipefail` that 141 ends the
# recording before the closing line. awk stops on its own instead.
PROFILE_STACK="curl -s '$PPROF?debug=2' | awk '/chan send/ {f=1} f {print; if (++n == 5) exit}' | sed -e \"s|\$PWD/||\" -e 's/ +0x[0-9a-f]*//'"
