#!/usr/bin/env bash
# One-time setup and preflight check. Run this before the talk, not during it.
#
#   ./scripts/setup.sh          # check everything, start Jaeger, build all demos
#   ./scripts/setup.sh --check  # check only, change nothing
#
# Every failure here is one that would otherwise happen on stage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_ylw=$'\033[1;33m'
c_blu=$'\033[1;34m'; c_dim=$'\033[2m';    c_off=$'\033[0m'

log()  { printf '%s==>%s %s\n' "$c_blu" "$c_off" "$*"; }
ok()   { printf '%s ok %s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s /!\\%s %s\n' "$c_ylw" "$c_off" "$*" >&2; PROBLEMS=$((PROBLEMS + 1)); }
bad()  { printf '%sERR%s %s\n' "$c_red" "$c_off" "$*" >&2; FATAL=$((FATAL + 1)); }
note() { printf '%s    %s%s\n' "$c_dim" "$*" "$c_off"; }

PROBLEMS=0
FATAL=0

# --- Go ---------------------------------------------------------------------

log "toolchain"
if ! command -v go >/dev/null 2>&1; then
  bad "go is not on PATH. Install Go 1.26 or newer: https://go.dev/dl/"
else
  gover="$(go env GOVERSION | sed 's/^go//')"
  gomajor="${gover%%.*}"
  gominor="$(printf '%s' "$gover" | cut -d. -f2)"
  if [ "${gomajor:-0}" -lt 1 ] || { [ "$gomajor" -eq 1 ] && [ "${gominor:-0}" -lt 26 ]; }; then
    # 1.26 is not decoration: demo 3 uses runtime/trace.FlightRecorder (1.25+)
    # and the tests use testing.B.Loop (1.24+).
    bad "Go $gover is too old. Demo 3 needs runtime/trace.FlightRecorder (Go 1.25+); this repo targets 1.26."
  else
    # `go env GOMAXPROCS` is empty unless it has been set explicitly, so ask the
    # runtime. Demo 3's expected numbers depend on this value, which is why it is
    # worth printing at setup time rather than leaving people to wonder why their
    # speedup was 8x and the README says 4x.
    ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo '?')"
    ok "go $gover ($(go env GOOS)/$(go env GOARCH), GOMAXPROCS=$ncpu)"
    if [ "$ncpu" != '?' ] && [ "${ncpu:-0}" -lt 4 ] 2>/dev/null; then
      warn "GOMAXPROCS=$ncpu — demo 3 shows a ${ncpu}x speedup, not the 4x in its README"
    fi
  fi
fi

for c in curl python3; do
  if command -v "$c" >/dev/null 2>&1; then
    ok "$c present"
  else
    warn "$c missing — used to fetch profiles and print trace waterfalls"
  fi
done

if command -v lsof >/dev/null 2>&1 || command -v ss >/dev/null 2>&1; then
  ok "lsof or ss present (needed to detect stale processes on demo ports)"
else
  bad "need lsof or ss: the demos refuse to start if they cannot verify port ownership"
fi

# --- platform ---------------------------------------------------------------

log "platform"
case "$(uname -s)" in
  Linux)
    ok "Linux — all four demos run natively, including eBPF"
    if command -v offcputime-bpfcc >/dev/null 2>&1 || command -v offcputime >/dev/null 2>&1; then
      ok "BCC offcputime present; 'make -C demo-04-cpu-quota investigate' checks the rest"
    else
      warn "no BCC offcputime — demo 4's off-CPU capture needs 'apt-get install bpfcc-tools'"
    fi
    ;;
  Darwin)
    ok "macOS — demos 1, 2, 3 run natively"
    note "Demo 4's 'make before' and 'make after' work here; 'make investigate' does not."
    note "BCC needs kernel headers, which Docker Desktop's linuxkit VM does not ship."
    note "  limactl start --name=ebpf template://ubuntu-lts"
    ;;
  *)
    warn "untested platform $(uname -s); demos 1-3 should still work"
    ;;
esac

# --- ports ------------------------------------------------------------------

# Every port this repository binds, and who wants it. A squatter here is the most
# common cause of a demo that starts but shows the wrong numbers, because the
# stale process answers instead.
log "ports"
port_owner() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1
  else
    ss -lptnH "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2
  fi
}

CLASH=0
check_port() {
  local port="$1" who="$2" pid
  pid="$(port_owner "$port")"
  if [ -z "$pid" ]; then
    printf '  %s ok %s :%-6s free%s (%s)%s\n' "$c_grn" "$c_off" "$port" "$c_dim" "$who" "$c_off"
    return 0
  fi
  local cmd
  cmd="$(ps -o comm= -p "$pid" 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo '?')"
  printf '  %s/!\\%s :%-6s held by pid %s (%s) — wanted by %s\n' \
    "$c_ylw" "$c_off" "$port" "$pid" "$cmd" "$who"
  CLASH=$((CLASH + 1))
  return 1
}

check_port 8080 "demo 1 frontend"       || true
check_port 6060 "demo 1 pprof"          || true
check_port 8085 "demo 1 profile-svc"    || true
check_port 8086 "demo 1 recommend-svc"  || true
check_port 8087 "demo 1 inventory-svc"  || true
check_port 8081 "demo 2 work service"   || true
check_port 6061 "demo 2 metrics + pprof" || true
check_port 8082 "demo 3 compute"        || true
check_port 6062 "demo 3 pprof + trace"  || true
check_port 8083 "demo 4 frontend"       || true
check_port 6063 "demo 4 pprof"          || true
check_port 8093 "demo 4 slow backend"   || true
check_port 4318 "Jaeger OTLP/HTTP"      || true
check_port 16686 "Jaeger UI"            || true

if [ "$CLASH" -gt 0 ]; then
  # Count once, not once per port: a held port is one problem to solve, and the
  # verdict at the end must not say "ready" while the port list says otherwise.
  PROBLEMS=$((PROBLEMS + 1))
  note ""
  note "$CLASH port(s) already in use. 'make clean' releases the ones this repo owns."
  note "If another project holds 4318/16686, either stop it or point demo 1 elsewhere:"
  note "  docker compose down                     # if it is an older Jaeger of yours"
  note "  OTLP_HTTP_PORT=14318 JAEGER_UI_PORT=26686 make setup"
  note "  make demo1-broken OTLP_ENDPOINT=localhost:14318 JAEGER_URL=http://localhost:26686"
fi

# --- docker -----------------------------------------------------------------

log "docker (demo 1 only)"
DOCKER_OK=0
if ! command -v docker >/dev/null 2>&1; then
  warn "docker not found — demo 1 needs it for Jaeger. Demos 2, 3, 4 do not need Docker at all."
elif ! docker info >/dev/null 2>&1; then
  warn "docker is installed but not running — start Docker Desktop, or skip demo 1"
elif ! docker compose version >/dev/null 2>&1; then
  warn "'docker compose' unavailable (v1 'docker-compose' is not used here)"
else
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') with compose"
  DOCKER_OK=1
fi

# --- build ------------------------------------------------------------------

log "build"
if [ "$CHECK_ONLY" -eq 1 ]; then
  if go build ./... 2>/tmp/gobuild.err; then
    ok "everything compiles"
  else
    bad "build failed:"; sed 's/^/    /' /tmp/gobuild.err >&2
  fi
  if go vet ./... 2>/tmp/govet.err; then
    ok "go vet clean"
  else
    warn "go vet reported:"; sed 's/^/    /' /tmp/govet.err >&2
  fi
else
  for d in demo-01-otel-sequential-calls demo-02-goroutine-leak \
           demo-03-lock-contention demo-04-cpu-quota; do
    if make -s -C "$d" build >/tmp/build-$$.err 2>&1; then
      ok "$d built"
    else
      bad "$d failed to build:"; sed 's/^/    /' /tmp/build-$$.err >&2
    fi
  done
  rm -f /tmp/build-$$.err
fi

# --- jaeger -----------------------------------------------------------------

if [ "$CHECK_ONLY" -eq 0 ] && [ "$DOCKER_OK" -eq 1 ]; then
  log "starting Jaeger"
  otlp_port="${OTLP_HTTP_PORT:-4318}"
  ui_port="${JAEGER_UI_PORT:-16686}"

  existing="$(port_owner "$otlp_port")"
  if [ -n "$existing" ] && ! docker ps --filter name=gcdemo-jaeger --format '{{.Names}}' | grep -q gcdemo-jaeger; then
    # Something else already speaks OTLP here. Demo 1 will work against it if it
    # is a real collector, so probe rather than refuse.
    if curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:$ui_port/api/services" | grep -q '^2'; then
      ok "an OTLP collector with a Jaeger query API is already on :$otlp_port/:$ui_port — using it"
      note "Not started by this repo (pid $existing). 'make down' will not stop it."
    else
      warn "port $otlp_port is held by pid $existing and does not answer the Jaeger query API"
      note "Stop it, or use different ports:"
      note "  OTLP_HTTP_PORT=14318 JAEGER_UI_PORT=26686 make setup"
    fi
  else
    if docker compose up -d 2>/tmp/compose.err; then
      # Wait for readiness rather than sleeping: compose returns as soon as the
      # container is created, which is well before Jaeger accepts spans.
      deadline=$(( $(date +%s) + 60 ))
      until curl -s -o /dev/null --max-time 2 "http://localhost:$ui_port/api/services"; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
          bad "Jaeger did not become ready in 60s. Logs:"
          docker compose logs --tail 20 jaeger >&2 || true
          break
        fi
        sleep 0.5
      done
      if curl -s -o /dev/null --max-time 2 "http://localhost:$ui_port/api/services"; then
        ok "Jaeger ready — UI http://localhost:$ui_port, OTLP/HTTP localhost:$otlp_port"
      fi
    else
      bad "docker compose up failed:"; sed 's/^/    /' /tmp/compose.err >&2
    fi
  fi
fi

# --- optional extras --------------------------------------------------------

log "optional"
if [ -n "${FLAMEGRAPH_DIR:-}" ] && [ -x "${FLAMEGRAPH_DIR}/flamegraph.pl" ]; then
  ok "FlameGraph at $FLAMEGRAPH_DIR (demo 4 will render an SVG)"
elif command -v flamegraph.pl >/dev/null 2>&1; then
  ok "flamegraph.pl on PATH"
else
  note "FlameGraph not installed (optional; demo 4 still writes folded stacks)"
  note "  git clone https://github.com/brendangregg/FlameGraph ~/FlameGraph"
  note "  export FLAMEGRAPH_DIR=~/FlameGraph"
fi

if command -v dot >/dev/null 2>&1; then
  ok "graphviz present (pprof -web, demo 3)"
else
  note "graphviz missing — 'make demo3-mutex-web' needs it: brew install graphviz / apt-get install graphviz"
fi

# --- verdict ----------------------------------------------------------------

printf '\n'
if [ "$FATAL" -gt 0 ]; then
  printf '%s%d fatal problem(s)%s and %d warning(s). Fix the fatal ones before the talk.\n' \
    "$c_red" "$FATAL" "$c_off" "$PROBLEMS"
  exit 1
fi
if [ "$PROBLEMS" -gt 0 ]; then
  printf '%sready with %d warning(s)%s — see above; none of them block demos 2 and 3.\n' \
    "$c_ylw" "$PROBLEMS" "$c_off"
else
  printf '%sready%s — all four demos should run.\n' "$c_grn" "$c_off"
fi

printf '\nRehearse the whole set now, which is the only real check:\n'
printf '  make rehearse\n'
exit 0
