// Package metrics exposes demo 3's Prometheus instrumentation.
//
// The job of these metrics is to make the *symptom* visible from outside the
// process: many workers alive, plenty of CPU available, and about one core's
// worth of it being used. That contrast is what a dashboard can show and what
// makes someone go looking. It is not the diagnosis — the mutex profile and the
// execution trace are still the only things that name the critical section.
//
// Five application metrics, and no more. Each one answers a question the demo
// actually asks on stage:
//
//	demo3_requests_total            is the service being driven?
//	demo3_request_duration_seconds  is it slower under concurrency?
//	demo3_items_processed_total     is it getting the same work done?
//	demo3_active_workers            are the goroutines actually there?
//	demo3_mutex_wait_seconds_total  are they spending their lives queueing?
//
// The standard Go and process collectors supply the rest, and they are the ones
// that carry the argument: process_cpu_seconds_total against
// go_sched_gomaxprocs_threads is the whole "16 workers, N cores, ~1 core used"
// slide.
package metrics

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Set is demo 3's application metrics, bound to one registry.
//
// Every metric carries a mode label so a Prometheus that scraped both halves of
// the demo can put them side by side. The label is bounded to exactly two values
// by the flag validation in main, and it is deliberately absent from the
// standard process and Go collectors: process_cpu_seconds_total describes the
// process, not a request, and labelling it by mode would invite a query that
// sums two different processes' CPU time.
type Set struct {
	Requests   *prometheus.CounterVec
	Duration   *prometheus.HistogramVec
	Items      *prometheus.CounterVec
	Workers    *prometheus.GaugeVec
	MutexWait  *prometheus.CounterVec
	registry   *prometheus.Registry
	defaultMod string

	// The per-mode series, resolved once.
	//
	// WithLabelValues takes the vec's own lock on every call to hash the labels and
	// look up the child. With a hundred workers entering and leaving, that showed up
	// in the *unlocked* mode's blocking profile at 9 % — the instrumentation appearing
	// as evidence in the very profile the demo asks the audience to read. There are
	// exactly two modes and they are known at startup, so resolving both here makes
	// the hot path a plain map read of an immutable map and an atomic add.
	byMode map[string]*modeSeries
}

// modeSeries is one mode's already-resolved children.
type modeSeries struct {
	workers   prometheus.Gauge
	mutexWait prometheus.Counter
	items     prometheus.Counter
	duration  prometheus.Observer
	ok        prometheus.Counter
	cancelled prometheus.Counter
}

// New builds the metrics on a dedicated registry and returns them with the
// /metrics handler.
//
// A dedicated registry, not prometheus.DefaultRegisterer: client_golang's own
// init installs the Go and process collectors on the default one, so registering
// them again there panics on a duplicate. It also means /metrics carries exactly
// what is registered here and nothing a future import might add — and, because
// each call gets a fresh registry, tests can build a Set per test without the
// second one panicking.
func New(defaultMode string) (*Set, http.Handler) {
	reg := prometheus.NewRegistry()

	s := &Set{
		registry:   reg,
		defaultMod: defaultMode,
		Requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "demo3_requests_total",
			Help: "Batch requests handled, by mode and outcome.",
		}, []string{"mode", "outcome"}),
		// Buckets span 10ms to ~26s because the two modes live in different
		// decades: 16 tasks x 100ms is ~0.15s of wall clock when they run in
		// parallel and ~1.6s when they queue, and under load the locked mode's
		// p95 reaches ten seconds. Prometheus' defaults stop at 10s, which would
		// put every interesting locked-mode observation in +Inf and make
		// histogram_quantile report a lower bound instead of a latency.
		Duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "demo3_request_duration_seconds",
			Help:    "Wall-clock time to process one batch, by mode.",
			Buckets: prometheus.ExponentialBuckets(0.01, 2, 14),
		}, []string{"mode"}),
		Items: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "demo3_items_processed_total",
			Help: "Work items completed, by mode.",
		}, []string{"mode"}),
		// A gauge, because the question is "how many right now". Its ceiling is
		// the interesting reading in locked mode: the workers are all there, all
		// alive, and all but one of them are queued on a lock.
		Workers: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "demo3_active_workers",
			Help: "Worker goroutines currently processing a batch item, computing or waiting for the mutex, by mode.",
		}, []string{"mode"}),
		// Seconds summed across goroutines, so it climbs faster than the clock
		// when many workers wait at once — 16 workers queued for a second add 16
		// seconds. That is the point: rate() on it reads as "seconds of waiting
		// per second", which is a count of goroutines doing nothing.
		MutexWait: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "demo3_mutex_wait_seconds_total",
			Help: "Time workers spent waiting to acquire the store mutex, summed across goroutines, by mode.",
		}, []string{"mode"}),
	}

	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		s.Requests, s.Duration, s.Items, s.Workers, s.MutexWait,
	)

	// Resolve both modes up front. This doubles as the initialisation that makes
	// /metrics non-empty before the first request: a query that returns "no data"
	// during a talk is indistinguishable from a broken scrape config.
	//
	// Both modes and not only defaultMode, because ?mode= on a request can select
	// the other one, and because the label is what lets a Prometheus that scraped
	// both halves of the demo put them side by side.
	s.byMode = make(map[string]*modeSeries, 2)
	for _, mode := range []string{"locked", "unlocked"} {
		s.byMode[mode] = &modeSeries{
			workers:   s.Workers.WithLabelValues(mode),
			mutexWait: s.MutexWait.WithLabelValues(mode),
			items:     s.Items.WithLabelValues(mode),
			duration:  s.Duration.WithLabelValues(mode),
			ok:        s.Requests.WithLabelValues(mode, "ok"),
			cancelled: s.Requests.WithLabelValues(mode, "cancelled"),
		}
	}

	return s, promhttp.HandlerFor(reg, promhttp.HandlerOpts{})
}

// Registry exposes the registry so tests can gather without an HTTP round trip.
func (s *Set) Registry() *prometheus.Registry { return s.registry }

// series returns a mode's resolved children, falling back to the process's own
// mode for anything unexpected. Nothing can pass an unknown mode — main and the
// handler both validate it against locked|unlocked — but a metrics call must never be
// the thing that panics a demo.
func (s *Set) series(mode string) *modeSeries {
	if m, ok := s.byMode[mode]; ok {
		return m
	}
	return s.byMode[s.defaultMod]
}

// ObserveMutexWait records one worker's wait for the store mutex.
func (s *Set) ObserveMutexWait(mode string, seconds float64) {
	s.series(mode).mutexWait.Add(seconds)
}

// WorkerEnter marks one worker as active and returns the func that marks it
// done. Returning the leave func rather than exposing an Add(-1) is what keeps
// the gauge balanced: the caller writes `defer m.WorkerEnter(mode)()` and cannot
// forget the other half.
func (s *Set) WorkerEnter(mode string) func() {
	g := s.series(mode).workers
	g.Inc()
	return g.Dec
}

// ObserveItems records completed work items.
func (s *Set) ObserveItems(mode string, n int) {
	s.series(mode).items.Add(float64(n))
}

// ObserveRequest records one finished batch request.
func (s *Set) ObserveRequest(mode, outcome string, seconds float64) {
	m := s.series(mode)
	if outcome == "ok" {
		m.ok.Inc()
	} else {
		m.cancelled.Inc()
	}
	// Only successful batches contribute to the latency histogram. A cancelled
	// request's duration is the client's timeout, not the service's latency, and
	// mixing the two would make the locked mode look *faster* the sooner clients
	// gave up on it.
	if outcome == "ok" {
		m.duration.Observe(seconds)
	}
}
