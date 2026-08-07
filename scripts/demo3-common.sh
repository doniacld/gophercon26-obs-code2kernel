#!/usr/bin/env bash
# The commands demo 3's three parts share. Strings, not functions, so liverun
# prints the command the audience is meant to read.

APP=http://localhost:8082
DIAG=http://localhost:6062
METRICS="$DIAG/metrics"

SCRAPE="curl -s $METRICS | grep -E '^demo3_active_workers|^go_sched_gomaxprocs_threads|^process_cpu_seconds_total|^go_goroutines'"
CORES="./scripts/cores.sh 6062"
WAIT_RATE="./scripts/waitrate.sh 6062"
ONE="curl -s '$APP/compute' | python3 -m json.tool"
CPU="make profile-cpu"
MUTEX="make profile-mutex"
SYNC="make sync"
SCHED="make sched"
