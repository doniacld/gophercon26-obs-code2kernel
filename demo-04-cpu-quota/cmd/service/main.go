// Command demo4-service serves POST /compute and GET /compute on :8083, with
// pprof on :6063.
//
// Both modes run *identical code*. There is no -mode flag that changes what this
// program does, and that is the entire architecture of the demo: the difference
// between fast and slow lives outside the process, in the cgroup's CPU quota. The
// two modes are two `--cpus=` values over one image:
//
//	throttled   --cpus=0.25         the bug
//	corrected   --cpus=3            the fix
//
// So the usual before/after comparison is inverted here. In demos 1, 2 and 3 you
// change the code and hold the environment still. Here you hold the code still —
// byte for byte, the same image — and change the environment. When the audience
// asks "what did you edit?", the answer is nothing.
//
// The binary is named demo4-service because the eBPF capture may filter on the
// process's comm, and Linux truncates comm to 15 characters — "demo4-service" is
// 13, so it survives intact.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/doniacld/go-observability-demos/demo-04-cpu-quota/internal/cgroup"
	"github.com/doniacld/go-observability-demos/demo-04-cpu-quota/internal/hash"
	"github.com/doniacld/go-observability-demos/internal/diag"
	"github.com/doniacld/go-observability-demos/internal/httpsrv"
)

func main() {
	var (
		addr      = flag.String("addr", ":8083", "application listen address")
		diagAddr  = flag.String("diag-addr", ":6063", "diagnostics listen address (pprof)")
		rounds    = flag.Int("rounds", hash.DefaultRounds, "SHA-256 rounds per request (~150ms unthrottled at the default)")
		maxRounds = flag.Int("max-rounds", 200000, "upper bound on ?rounds=, so a stray query cannot wedge the demo")
		shards    = flag.Int("shards", 1, "goroutines per request; 1 keeps per-request cost readable")
		jobs      = flag.Int("jobs", hash.DefaultJobs, "default job count for POST /compute")
		jobRounds = flag.Int("job-rounds", hash.JobRounds, "SHA-256 rounds per job for POST /compute (~73ms of one core each)")
		// Echoed as "mode" in every reply, so what is passed here is on screen from
		// act 1 onwards. docker-compose.yml passes "baseline" for the throttled
		// container for exactly that reason: naming the quota in the service's first
		// reply would answer the demo before a single tool has been used.
		label = flag.String("label", "", "mode label for logs and /stats (e.g. baseline|corrected)")
	)
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))

	if *rounds < 1 || *rounds > *maxRounds {
		log.Error("-rounds must be between 1 and -max-rounds", "rounds", *rounds, "max_rounds", *maxRounds)
		os.Exit(2)
	}
	if *shards < 1 || *shards > 256 {
		log.Error("-shards must be between 1 and 256", "shards", *shards)
		os.Exit(2)
	}
	if *jobs < 1 || *jobs > 256 {
		log.Error("-jobs must be between 1 and 256", "jobs", *jobs)
		os.Exit(2)
	}
	if *jobRounds < 1 || *jobRounds > *maxRounds {
		log.Error("-job-rounds must be between 1 and -max-rounds", "job_rounds", *jobRounds, "max_rounds", *maxRounds)
		os.Exit(2)
	}

	// Read the quota once at startup and the counters continuously. If this is not
	// Linux, or not cgroup v2, say so once here rather than serving zeros from
	// /stats and letting the audience believe a measurement happened.
	quota, quotaErr := cgroup.ReadQuota()
	baseline, statErr := cgroup.ReadStat()

	svc := &service{
		log:       log,
		label:     *label,
		rounds:    *rounds,
		maxRounds: *maxRounds,
		shards:    *shards,
		jobs:      *jobs,
		jobRounds: *jobRounds,
		baseline:  baseline,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /compute", svc.compute)
	mux.HandleFunc("POST /compute", svc.computeJobs)
	mux.HandleFunc("GET /stats", svc.stats)
	mux.HandleFunc("GET /throttle", svc.throttle)
	mux.HandleFunc("GET /reset", svc.reset)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	dsrv := diag.New(*diagAddr)
	if err := dsrv.Start(); err != nil {
		log.Error("diagnostics listener failed", "error", err)
		os.Exit(1)
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = dsrv.Shutdown(ctx)
	}()

	err := httpsrv.Run(*addr, mux, func(bound string) {
		log.Info("demo 4 service ready",
			"demo", 4,
			"mode", labelOrUnset(*label),
			"addr", bound,
			"diag", dsrv.Addr,
			"pprof", dsrv.URL("/debug/pprof/"),
			"rounds_per_request", *rounds,
			"buffer_bytes", hash.BufferSize,
			"shards_per_request", *shards,
			"GOMAXPROCS", runtime.GOMAXPROCS(0),
			"NumCPU", runtime.NumCPU(),
			"cpu.max", quotaString(quota, quotaErr),
			"pid", os.Getpid(),
		)

		// The most surprising line in the demo, and the reason it is logged at
		// startup rather than buried in /stats. On Go 1.25+ the runtime derives
		// GOMAXPROCS from the cgroup quota, so a throttled container does *not*
		// show GOMAXPROCS == NumCPU. The runtime already adapted. It was not
		// enough, and that is the story.
		switch {
		case quotaErr != nil:
			log.Warn("no cgroup v2 CPU quota visible — this is the unlimited reference, "+
				"or a host where the quota cannot be read (macOS, cgroup v1)",
				"error", quotaErr)
		case quota.Unlimited:
			log.Info("cpu.max is 'max' — no quota. This is the reference run, not the fix")
		default:
			log.Warn("a CPU quota is in force",
				"quota_cores", fmt.Sprintf("%.2f", quota.Cores()),
				"GOMAXPROCS", runtime.GOMAXPROCS(0),
				"NumCPU", runtime.NumCPU(),
				"note", "the Go runtime derived GOMAXPROCS from this quota; "+
					"if GOMAXPROCS still exceeds the quota, every busy period will be throttled")
		}
		if statErr != nil {
			log.Warn("cpu.stat is not readable — the throttling counters will be absent",
				"error", statErr, "endpoint", "/throttle")
		}

		log.Info("first observation (it will not explain the latency — that is the point)", "cmd",
			fmt.Sprintf(`curl -o cpu.pprof "%s?seconds=15" && go tool pprof -top cpu.pprof`,
				dsrv.URL("/debug/pprof/profile")))
		log.Info("the reveal", "cmd", "curl -s http://localhost"+portOf(bound)+"/throttle")
	})
	if err != nil {
		log.Error("server stopped", "error", err)
		os.Exit(1)
	}
	log.Info("service stopped")
}

type service struct {
	log       *slog.Logger
	label     string
	rounds    int
	maxRounds int
	shards    int
	jobs      int
	jobRounds int

	// baseline is the cpu.stat reading from startup, so /throttle can report a
	// delta for this process's lifetime and /reset can rebase it per load run.
	mu       sync.Mutex
	baseline cgroup.Stat

	requests atomic.Int64
	totalNS  atomic.Int64
	maxNS    atomic.Int64
	digests  sync.Map // digest -> struct{}, to prove every request did the same work
}

// compute handles GET /compute: hash a fixed buffer a fixed number of times.
//
//	/compute?rounds=12000   override the round count, bounded by -max-rounds
//
// No lock, no I/O, no downstream call, no sleep. One request is one deterministic
// block of arithmetic, so the only thing that can make it slow is not being given
// a CPU to run on.
func (s *service) compute(w http.ResponseWriter, r *http.Request) {
	rounds := s.rounds
	if v := r.URL.Query().Get("rounds"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > s.maxRounds {
			http.Error(w, fmt.Sprintf("rounds=%s: want an integer between 1 and %d", v, s.maxRounds),
				http.StatusBadRequest)
			return
		}
		rounds = n
	}

	start := time.Now()
	res := s.run(rounds)
	elapsed := time.Since(start)

	s.record(elapsed, res.Digest)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"mode":       labelOrUnset(s.label),
		"rounds":     res.Rounds,
		"digest":     res.Digest[:16],
		"elapsed_ms": msFloat(elapsed),
		"gomaxprocs": runtime.GOMAXPROCS(0),
		"numcpu":     runtime.NumCPU(),
	})
}

// computeJobs handles POST /compute with a body of {"jobs": 16}.
//
// This is the request the before/investigate/after flow uses, and the reason it
// exists next to GET /compute is the off-CPU capture. One job means one runnable
// goroutine, and a single thread's wait is not much of a flame graph. Sixteen
// runnable jobs against a quarter of a core means most of them are parked waiting
// for a CPU at any instant — which is exactly the time that no CPU profile can
// see and the off-CPU stacks can.
//
// The work is identical in every mode. Same endpoint, same body, same job count,
// same rounds per job, same digest. Only the cgroup quota around the process
// differs, which is the entire claim of the demo.
func (s *service) computeJobs(w http.ResponseWriter, r *http.Request) {
	// A missing or empty body means "use the defaults", so `curl -X POST` with no
	// -d still works when someone is driving this by hand.
	req := struct {
		Jobs   int `json:"jobs"`
		Rounds int `json:"rounds"`
	}{Jobs: s.jobs, Rounds: s.jobRounds}

	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	if err := dec.Decode(&req); err != nil && err != io.EOF {
		http.Error(w, fmt.Sprintf("body: want JSON like {\"jobs\":%d}: %v", s.jobs, err),
			http.StatusBadRequest)
		return
	}
	if req.Jobs < 1 || req.Jobs > 256 {
		http.Error(w, fmt.Sprintf("jobs=%d: want between 1 and 256", req.Jobs), http.StatusBadRequest)
		return
	}
	if req.Rounds < 1 || req.Rounds > s.maxRounds {
		http.Error(w, fmt.Sprintf("rounds=%d: want between 1 and %d", req.Rounds, s.maxRounds),
			http.StatusBadRequest)
		return
	}

	start := time.Now()
	res := hash.ComputeJobs(req.Jobs, req.Rounds)
	elapsed := time.Since(start)

	s.record(elapsed, res.Digest)

	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(map[string]any{
		"mode":             labelOrUnset(s.label),
		"jobs":             req.Jobs,
		"rounds_per_job":   req.Rounds,
		"digest":           res.Digest[:16],
		"elapsed_ms":       msFloat(elapsed),
		"cpu_work_core_ms": round2(float64(req.Jobs*req.Rounds) / float64(hash.JobRounds) * 73),
		"gomaxprocs":       runtime.GOMAXPROCS(0),
		"numcpu":           runtime.NumCPU(),
	})
}

// record updates the shared request accounting. Shared by both /compute handlers
// so the worst-request tracking cannot drift between them.
func (s *service) record(elapsed time.Duration, digest string) {
	s.requests.Add(1)
	s.totalNS.Add(int64(elapsed))
	for {
		// Track the worst request seen. Under a quota the mean understates the
		// damage badly, because a request either fits inside the remaining
		// allowance or waits a whole period for the next one.
		old := s.maxNS.Load()
		if int64(elapsed) <= old || s.maxNS.CompareAndSwap(old, int64(elapsed)) {
			break
		}
	}
	s.digests.Store(digest, struct{}{})
}

// run does the work, optionally across -shards goroutines.
//
// The digest is deliberately derived from shard 0 only, so the result is
// independent of how the work was split and the equivalence assertion holds for
// any -shards value. Sharding exists to let a single request saturate more than
// one core on demand; the default of 1 keeps "one request costs 150 ms" true.
func (s *service) run(rounds int) hash.Result {
	if s.shards == 1 {
		return hash.Compute(rounds, 0)
	}

	results := make([]hash.Result, s.shards)
	var wg sync.WaitGroup
	for i := 0; i < s.shards; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i] = hash.Compute(rounds, 0)
		}(i)
	}
	wg.Wait()
	return results[0]
}

// stats reports the service's own accounting plus the runtime's view of how much
// CPU it believes it may use.
//
// gomaxprocs beside numcpu and quota_cores is the interesting triple. On a
// throttled container all three disagree, and the disagreement is the diagnosis.
func (s *service) stats(w http.ResponseWriter, r *http.Request) {
	n := s.requests.Load()
	var mean float64
	if n > 0 {
		mean = float64(s.totalNS.Load()) / float64(n) / 1e6
	}

	var uniqueDigests int
	s.digests.Range(func(_, _ any) bool { uniqueDigests++; return true })

	payload := map[string]any{
		"mode":           labelOrUnset(s.label),
		"pid":            os.Getpid(),
		"requests":       n,
		"mean_ms":        round2(mean),
		"max_ms":         round2(float64(s.maxNS.Load()) / 1e6),
		"rounds":         s.rounds,
		"shards":         s.shards,
		"gomaxprocs":     runtime.GOMAXPROCS(0),
		"numcpu":         runtime.NumCPU(),
		"goroutines":     runtime.NumGoroutine(),
		"unique_digests": uniqueDigests,
		"cgroup_v2":      cgroup.Available(),
	}

	if q, err := cgroup.ReadQuota(); err == nil {
		payload["cpu_max"] = q.Raw
		payload["quota_cores"] = q.Cores()
		payload["quota_unlimited"] = q.Unlimited
		// Oversubscription is the number that explains the throttling: how many
		// runnable threads the runtime is willing to schedule, against how many
		// cores' worth of time the kernel will actually grant. Above 1.0, busy
		// periods must be cut short.
		if !q.Unlimited && q.Cores() > 0 {
			payload["oversubscription"] = round2(float64(runtime.GOMAXPROCS(0)) / q.Cores())
		}
	}

	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(payload)
}

// throttle reports the cgroup CPU throttling counters as a delta since the last
// /reset (or since startup).
//
// THE REVEAL, and it needs no privileges and no tooling — this is a read of a
// text file the kernel maintains. nr_throttled against nr_periods is the whole
// diagnosis: it says how many enforcement periods ended with runnable work
// forbidden to continue.
func (s *service) throttle(w http.ResponseWriter, r *http.Request) {
	now, err := cgroup.ReadStat()
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"available": false,
			"error":     err.Error(),
			"note": "cgroup v2 cpu.stat is not readable here. This is expected on macOS " +
				"and on cgroup v1 hosts; run the service in a container on a cgroup v2 host.",
		})
		return
	}

	s.mu.Lock()
	delta := now.Sub(s.baseline)
	s.mu.Unlock()

	payload := map[string]any{
		"available":        true,
		"mode":             labelOrUnset(s.label),
		"since":            "last /reset",
		"nr_periods":       delta.NrPeriods,
		"nr_throttled":     delta.NrThrottled,
		"throttled_ratio":  round2(delta.ThrottledRatio()),
		"throttled_ms":     round2(float64(delta.ThrottledUS) / 1000),
		"cpu_usage_ms":     round2(float64(delta.UsageUS) / 1000),
		"cpu_user_ms":      round2(float64(delta.UserUS) / 1000),
		"cpu_system_ms":    round2(float64(delta.SystemUS) / 1000),
		"nr_periods_total": now.NrPeriods,
	}
	if now.Has("nr_bursts") {
		payload["nr_bursts"] = delta.NrBursts
		payload["burst_ms"] = round2(float64(delta.BurstUS) / 1000)
	}

	// Say what the numbers mean, in the response. This endpoint gets read aloud
	// from a terminal on stage, and a bare counter invites the wrong conclusion.
	switch {
	case delta.NrPeriods == 0:
		payload["verdict"] = "no enforcement periods in this window — either no quota, or no CPU demand"
	case delta.NrThrottled == 0:
		payload["verdict"] = "not throttled: the workload fitted inside its quota every period"
	case delta.NrThrottled == delta.NrPeriods:
		payload["verdict"] = fmt.Sprintf(
			"throttled in EVERY one of %d periods — the quota is below what this workload needs",
			delta.NrPeriods)
	default:
		payload["verdict"] = fmt.Sprintf("throttled in %d of %d periods (%.0f%%)",
			delta.NrThrottled, delta.NrPeriods, 100*delta.ThrottledRatio())
	}
	payload["note"] = "throttled_ms is summed across tasks, so it can exceed wall-clock time — " +
		"the same arithmetic as demo 3's contention delay"

	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(payload)
}

// reset zeroes the request counters and rebases the cgroup baseline, so the next
// load run's numbers belong to that run alone.
func (s *service) reset(w http.ResponseWriter, r *http.Request) {
	s.requests.Store(0)
	s.totalNS.Store(0)
	s.maxNS.Store(0)
	s.digests.Range(func(k, _ any) bool { s.digests.Delete(k); return true })

	if st, err := cgroup.ReadStat(); err == nil {
		s.mu.Lock()
		s.baseline = st
		s.mu.Unlock()
	}
	fmt.Fprintln(w, "reset")
}

func labelOrUnset(s string) string {
	if s == "" {
		return "unset"
	}
	return s
}

func quotaString(q cgroup.Quota, err error) string {
	if err != nil {
		return "unreadable"
	}
	return q.String()
}

// portOf turns a bound address like "[::]:8083" into ":8083" so the logged
// command is copy-pasteable.
func portOf(bound string) string {
	for i := len(bound) - 1; i >= 0; i-- {
		if bound[i] == ':' {
			return bound[i:]
		}
	}
	return bound
}

func msFloat(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

func round2(f float64) float64 { return float64(int(f*100+0.5)) / 100 }
