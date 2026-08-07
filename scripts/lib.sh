#!/usr/bin/env bash
# Shared process and readiness helpers for the demo Makefiles.
#
# The one rule this file exists to enforce: never let a stale process answer a
# request you believe is going to a freshly started one. That failure mode is
# silent — the demo appears to run, the numbers are simply from the previous
# build — and it is the single most likely way for a live demo to mislead an
# audience. Every start therefore writes a PID file and asserts that the process
# listening on the port is the one we just launched.

set -euo pipefail

RUN_DIR="${RUN_DIR:-.run}"
BIN_DIR="${BIN_DIR:-bin}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m /!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# port_pid PORT — the PID listening on PORT, or empty.
port_pid() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1
  elif command -v ss >/dev/null 2>&1; then
    ss -lptnH "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2
  else
    die "need lsof or ss to inspect ports"
  fi
}

# wait_tcp HOST PORT [TIMEOUT_S] — block until the port accepts a connection.
#
# A readiness check, not a sleep: on a cold laptop a fixed `sleep 2` races the
# server, and on a warm one it wastes two seconds of stage time.
wait_tcp() {
  local host="$1" port="$2" timeout="${3:-20}"
  local deadline=$(( $(date +%s) + timeout ))
  while :; do
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
      exec 3>&- 2>/dev/null || true
      return 0
    fi
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

# wait_http URL [TIMEOUT_S] — block until URL returns a 2xx/3xx.
wait_http() {
  local url="$1" timeout="${2:-30}"
  local deadline=$(( $(date +%s) + timeout ))
  while :; do
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url" 2>/dev/null || echo 000)
    case "$code" in 2??|3??) return 0 ;; esac
    [ "$(date +%s)" -ge "$deadline" ] && { warn "last status from $url was $code"; return 1; }
    sleep 0.3
  done
}

# start NAME PORT CMD... — launch CMD in the background, wait for PORT, and
# assert the port belongs to the process we started.
start() {
  local name="$1" port="$2"; shift 2
  mkdir -p "$RUN_DIR"
  stop "$name" >/dev/null 2>&1 || true

  # A leftover process from an earlier run, or another project, holding our
  # port. Refuse rather than launch a process that will fail to bind and leave
  # the old one answering.
  local squatter
  squatter=$(port_pid "$port" || true)
  if [ -n "$squatter" ]; then
    die "port $port is already held by pid $squatter — run 'make clean' or kill it before starting $name"
  fi

  "$@" > "$RUN_DIR/$name.log" 2>&1 &
  local pid=$!
  echo "$pid" > "$RUN_DIR/$name.pid"

  if ! wait_tcp 127.0.0.1 "$port" 25; then
    warn "$name did not bind :$port — last 30 log lines:"
    tail -30 "$RUN_DIR/$name.log" >&2 || true
    die "$name failed to start"
  fi

  local owner
  owner=$(port_pid "$port" || true)
  if [ -n "$owner" ] && [ "$owner" != "$pid" ]; then
    # On Linux the listener may be a child of the launched process; accept that,
    # reject an unrelated PID.
    if ! ps -o ppid= -p "$owner" 2>/dev/null | tr -d ' ' | grep -qx "$pid"; then
      die "port $port is served by pid $owner, not the $name we just started ($pid) — a stale process is answering"
    fi
  fi

  log "$name up on :$port (pid $pid, log $RUN_DIR/$name.log)"
}

# stop NAME — terminate the process recorded for NAME.
stop() {
  local name="$1"
  local pidfile="$RUN_DIR/$name.pid"
  [ -f "$pidfile" ] || return 0
  local pid
  pid=$(cat "$pidfile")
  if kill -0 "$pid" 2>/dev/null; then
    # SIGTERM first: the demos flush OpenTelemetry spans and shut listeners down
    # on SIGTERM, and SIGKILL would lose the last second of the trace.
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    log "$name (pid $pid) stopped"
  fi
  rm -f "$pidfile"
}

# stop_all — terminate every process recorded in RUN_DIR.
stop_all() {
  [ -d "$RUN_DIR" ] || return 0
  local f
  for f in "$RUN_DIR"/*.pid; do
    [ -e "$f" ] || continue
    stop "$(basename "$f" .pid)"
  done
  # Nothing is staged any more, so the recorded mode is no longer true.
  rm -f "$RUN_DIR/mode"
}

# status PORT... — report who owns each port.
status() {
  local port
  for port in "$@"; do
    local pid
    pid=$(port_pid "$port" || true)
    if [ -n "$pid" ]; then
      printf '  :%-6s pid %-8s %s\n' "$port" "$pid" "$(ps -o args= -p "$pid" 2>/dev/null | head -1 | cut -c1-70)"
    else
      printf '  :%-6s free\n' "$port"
    fi
  done
}

# record_mode MODE — remember which mode the running service was started in.
#
# `make trace` and `make capture` run in a fresh make process that does not know
# what `make fixed` chose, so a capture would default to MODE=broken and write
# trace-broken.out from a service running the fixed build. Mislabelled artifacts
# are worse than missing ones: on stage you would show the audience a "before"
# file recorded "after". The mode is written here and read back by running_mode.
record_mode() {
  mkdir -p "$RUN_DIR"
  printf '%s\n' "$1" > "$RUN_DIR/mode"
}

# running_mode [FALLBACK] — the mode of the currently staged service.
running_mode() {
  if [ -s "$RUN_DIR/mode" ]; then
    cat "$RUN_DIR/mode"
  else
    printf '%s' "${1:-broken}"
  fi
}

# require_cmd CMD... — fail with a useful message if a tool is missing.
require_cmd() {
  local missing=()
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "missing required command(s): ${missing[*]}"
  fi
}
