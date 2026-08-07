// Command compute serves GET /compute (also POST /process) on :8082, with
// Prometheus metrics, pprof, the mutex profile and the execution tracer on :6062.
//
//	-mode locked  the expensive CPU work happens while holding a global mutex
//	-mode unlocked   the work happens first; the mutex covers only the store
//
// Both modes launch identical goroutines, do identical work and produce
// identical checksums. Only the lock placement differs — which is precisely the
// kind of difference a CPU profile cannot show and a mutex profile plus an
// execution trace show immediately.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"time"

	"github.com/doniacld/go-observability-demos/demo-03-lock-contention/internal/metrics"
	"github.com/doniacld/go-observability-demos/demo-03-lock-contention/internal/work"
	"github.com/doniacld/go-observability-demos/internal/diag"
	"github.com/doniacld/go-observability-demos/internal/httpsrv"
)

func main() {
	var (
		addr         = flag.String("addr", ":8082", "application listen address")
		diagAddr     = flag.String("diag-addr", ":6062", "diagnostics listen address (pprof, mutex, trace)")
		mode         = flag.String("mode", "locked", "locked|unlocked")
		workItems    = flag.Int("work-items", 16, "independent tasks per request")
		workDuration = flag.Duration("work-duration", 100*time.Millisecond, "CPU time per task")
		maxItems     = flag.Int("max-items", 512, "hard upper bound on ?items=")
		maxDuration  = flag.Duration("max-duration", time.Second, "hard upper bound on ?duration=")
		mutexFrac    = flag.Int("mutex-profile-fraction", 1, "runtime.SetMutexProfileFraction; 0 disables")
		blockRate    = flag.Int("block-profile-rate", 10000, "runtime.SetBlockProfileRate in ns; 0 disables")
		flightWindow = flag.Duration("flight-window", 5*time.Second, "flight recorder history to retain (0 disables)")
	)
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))

	if *mode != "locked" && *mode != "unlocked" {
		log.Error("-mode must be locked or unlocked", "mode", *mode)
		os.Exit(2)
	}
	// Hard upper bounds, checked before anything starts. 512 items x 1s x 8
	// concurrent requests is already 68 minutes of queued CPU work in locked
	// mode; past that the demo stops being a demo and starts being a hung laptop.
	if *maxItems < 1 || *maxItems > 4096 {
		log.Error("-max-items must be between 1 and 4096", "max_items", *maxItems)
		os.Exit(2)
	}
	if *workItems < 1 || *workItems > *maxItems {
		log.Error("-work-items must be between 1 and -max-items", "work_items", *workItems, "max_items", *maxItems)
		os.Exit(2)
	}
	if *maxDuration <= 0 || *maxDuration > 10*time.Second {
		log.Error("-max-duration must be between 0 and 10s", "max_duration", *maxDuration)
		os.Exit(2)
	}
	if *workDuration <= 0 || *workDuration > *maxDuration {
		log.Error("-work-duration must be between 0 and -max-duration", "work_duration", *workDuration, "max_duration", *maxDuration)
		os.Exit(2)
	}

	// Mutex profiling is OFF by default in Go and must be enabled explicitly.
	// This is the single most common reason a mutex profile comes back empty:
	// nothing is broken, the runtime simply was not asked to collect it.
	//
	// The fraction is a 1-in-N sampling rate for contention *events*. 1 records
	// every one, which is what a demo wants and more than production usually
	// needs — the runtime does bookkeeping on each contended unlock, so a busy
	// service with a hot lock pays for it. 100 is a reasonable production value.
	//
	// Block profiling is enabled too, at 10µs. It covers a wider class of waits
	// (channels, selects, WaitGroup, and mutexes) and is the profile to reach for
	// when you do not yet know which primitive is responsible.
	runtime.SetMutexProfileFraction(*mutexFrac)
	runtime.SetBlockProfileRate(*blockRate)

	store := work.NewStore()

	// The metrics are attached to the store rather than compiled into it, so the
	// two modes still differ by lock placement alone.
	mset, metricsHandler := metrics.New(*mode)
	store.Observe(mset)

	svc := &service{
		log:          log,
		store:        store,
		metrics:      mset,
		mode:         *mode,
		workItems:    *workItems,
		workDuration: *workDuration,
		maxItems:     *maxItems,
		maxDuration:  *maxDuration,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /compute", svc.compute)
	// Same handler, two spellings: /compute is what the Makefile, the load
	// generator and every README line already call, and POST /process is the name
	// the batch reads as in a metrics dashboard.
	mux.HandleFunc("POST /process", svc.compute)
	mux.HandleFunc("GET /stats", svc.stats)
	mux.HandleFunc("GET /reset", svc.reset)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	dsrv := diag.New(*diagAddr)

	// /metrics goes on the diagnostics listener, next to pprof. A third port would
	// buy nothing: this is the same class of endpoint, scraped by the same kind of
	// tool, and the demo's point is precisely that the two live side by side and
	// answer different questions.
	dsrv.Handle("/metrics", metricsHandler)

	// The flight recorder keeps a rolling window of execution-trace data in
	// memory so a snapshot can be taken *after* something interesting happened.
	// Here the interesting thing is on demand and predictable, so it is a
	// convenience; in production it is the difference between having a trace of
	// the incident and a trace of the calm afterwards.
	var fr *diag.FlightRecorder
	if *flightWindow > 0 {
		var err error
		fr, err = diag.NewFlightRecorder(*flightWindow, 8<<20)
		if err != nil {
			log.Warn("flight recorder unavailable; /debug/flightrecorder disabled", "error", err)
		} else {
			defer fr.Stop()
			dsrv.HandleFunc("/debug/flightrecorder", fr.Handler())
		}
	}

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
		log.Info("demo 3 compute ready",
			"demo", 3,
			"mode", *mode,
			"addr", bound,
			"diag", dsrv.Addr,
			"pprof", dsrv.URL("/debug/pprof/"),
			"metrics", dsrv.URL("/metrics"),
			"work_items", *workItems,
			"work_duration", *workDuration,
			"max_items", *maxItems,
			"max_duration", *maxDuration,
			"mutex_profile_fraction", *mutexFrac,
			"block_profile_rate_ns", *blockRate,
			"GOMAXPROCS", runtime.GOMAXPROCS(0),
			"NumCPU", runtime.NumCPU(),
		)
		if *mode == "locked" {
			log.Warn("MODE=locked — the mutex is held across expensiveWork, so one task runs at a time process-wide",
				"expected_wall", time.Duration(*workItems)*(*workDuration))
		} else {
			log.Info("MODE=unlocked — the mutex covers storeResult only",
				"expected_wall", time.Duration(*workItems)*(*workDuration)/
					time.Duration(min(runtime.GOMAXPROCS(0), *workItems)))
		}
		log.Info("first reveal", "cmd",
			fmt.Sprintf(`curl -o mutex.pb.gz %s && go tool pprof -top mutex.pb.gz`,
				dsrv.URL("/debug/pprof/mutex")))
		log.Info("second reveal", "cmd",
			fmt.Sprintf(`curl -o trace.out "%s?seconds=8" && go tool trace trace.out`,
				dsrv.URL("/debug/pprof/trace")))
	})
	if err != nil {
		log.Error("server stopped", "error", err)
		os.Exit(1)
	}
	log.Info("compute stopped")
}

type service struct {
	log          *slog.Logger
	store        *work.Store
	metrics      *metrics.Set
	mode         string
	workItems    int
	workDuration time.Duration
	maxItems     int
	maxDuration  time.Duration
}

// compute handles GET /compute.
//
// Query parameters override the defaults per request so one running service can
// be pushed harder without a restart:
//
//	/compute?items=32&duration=50ms&mode=unlocked
//
// Values above the configured maximum are rejected with 400 rather than clamped.
// Silently serving 512 items when the URL said 50,000 would make the demo lie
// about what it just did.
func (s *service) compute(w http.ResponseWriter, r *http.Request) {
	mode := s.mode
	if v := r.URL.Query().Get("mode"); v != "" {
		if v != "locked" && v != "unlocked" {
			http.Error(w, fmt.Sprintf("mode=%s: want locked or unlocked", v), http.StatusBadRequest)
			return
		}
		mode = v
	}

	items := s.workItems
	if v := r.URL.Query().Get("items"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			http.Error(w, fmt.Sprintf("items=%s: want a positive integer", v), http.StatusBadRequest)
			return
		}
		if n > s.maxItems {
			http.Error(w, fmt.Sprintf("items=%d exceeds max-items=%d", n, s.maxItems), http.StatusBadRequest)
			return
		}
		items = n
	}

	dur := s.workDuration
	if v := r.URL.Query().Get("duration"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			http.Error(w, fmt.Sprintf("duration=%s: want a positive duration", v), http.StatusBadRequest)
			return
		}
		if d > s.maxDuration {
			http.Error(w, fmt.Sprintf("duration=%s exceeds max-duration=%s", d, s.maxDuration), http.StatusBadRequest)
			return
		}
		dur = d
	}

	started := time.Now()
	batch, err := s.store.Run(r.Context(), mode, work.Tasks(items, dur))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if batch.Cancelled {
		s.metrics.ObserveRequest(mode, "cancelled", time.Since(started).Seconds())
		// The client is gone; nothing will read this, but a status code makes the
		// abandonment visible in the load generator's summary rather than silent.
		http.Error(w, "request cancelled", http.StatusRequestTimeout)
		return
	}
	s.metrics.ObserveRequest(mode, "ok", time.Since(started).Seconds())
	s.metrics.ObserveItems(mode, batch.Items)

	// The response carries the diagnosis, not just the answer. speedup is
	// computed from timestamps the handler already had: 1.0 means the tasks ran
	// one after another, GOMAXPROCS means they ran together.
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"mode":          batch.Mode,
		"items":         batch.Items,
		"task_ms":       dur.Milliseconds(),
		"gomaxprocs":    batch.GOMAXPROCS,
		"wall_ms":       msFloat(batch.Wall),
		"cpu_time_ms":   msFloat(batch.CPUTime),
		"lock_wait_ms":  msFloat(batch.LockWait),
		"peak_working":  batch.PeakWorking,
		"speedup":       round2(batch.Speedup()),
		"critical_pct":  round2(criticalPct(batch)),
		"parallelism":   describe(batch),
		"checksum_head": head(batch),
	})
}

func (s *service) stats(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(s.store.Stats())
}

func (s *service) reset(w http.ResponseWriter, r *http.Request) {
	s.store.Reset()
	fmt.Fprintln(w, "reset")
}

// criticalPct is the share of the batch's total task-time spent waiting for the
// lock rather than computing. In locked mode it approaches 100 % as the item
// count grows — with 16 tasks the average task waits for 7.5 others. In unlocked
// mode it is a rounding error.
func criticalPct(b *work.Batch) float64 {
	total := b.LockWait + b.CPUTime
	if total <= 0 {
		return 0
	}
	return 100 * b.LockWait.Seconds() / total.Seconds()
}

// describe puts the speedup into words.
//
// The ceiling is peak_working, not GOMAXPROCS, and the two are not the same when
// items exceeds the processor count. expensiveWork burns CPU until a wall-clock
// deadline, so 16 tasks sharing 11 processors each complete less work than their
// nominal 100 ms — which makes cpu_time_ms an overestimate and pushes the
// reported speedup slightly above GOMAXPROCS. That is a property of the
// workload's deadline, not a measurement error, and peak_working is the number
// to trust when they disagree.
func describe(b *work.Batch) string {
	s := b.Speedup()
	switch {
	case s < 1.5:
		return fmt.Sprintf("serial: %d processors available, 1 task at a time", b.GOMAXPROCS)
	case s < float64(b.GOMAXPROCS)/2:
		return fmt.Sprintf("partial: %d tasks at once, %d processors", b.PeakWorking, b.GOMAXPROCS)
	default:
		return fmt.Sprintf("parallel: %d tasks at once, %d processors, %.1fx the serial rate",
			b.PeakWorking, b.GOMAXPROCS, s)
	}
}

// head returns the first few checksums, so an audience can see with their own
// eyes that the two modes compute the same answers.
func head(b *work.Batch) []uint64 {
	n := min(3, len(b.Results))
	out := make([]uint64, 0, n)
	for _, r := range b.Results[:n] {
		out = append(out, r.Checksum)
	}
	return out
}

func msFloat(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

func round2(f float64) float64 { return float64(int(f*100+0.5)) / 100 }
