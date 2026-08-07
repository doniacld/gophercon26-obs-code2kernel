package metrics

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	dto "github.com/prometheus/client_model/go"

	"github.com/doniacld/go-observability-demos/demo-03-lock-contention/internal/work"
)

// TestExpositionContainsWhatTheDemoReads scrapes the handler and asserts that
// every metric name the README's queries mention is actually in the output.
//
// The standard collectors' names are the point here. They are not ours, they
// change between client_golang versions, and a query in a slide deck that names a
// metric the binary does not export fails silently in front of an audience — the
// graph is simply empty.
func TestExpositionContainsWhatTheDemoReads(t *testing.T) {
	_, h := New("locked")

	body := scrape(t, h)

	for _, name := range []string{
		"demo3_requests_total",
		"demo3_request_duration_seconds_bucket",
		"demo3_items_processed_total",
		"demo3_active_workers",
		"demo3_mutex_wait_seconds_total",
		"process_cpu_seconds_total",
		"go_goroutines",
		"go_sched_gomaxprocs_threads",
	} {
		if !strings.Contains(body, name) {
			t.Errorf("/metrics does not export %s", name)
		}
	}
}

// TestSeriesExistBeforeAnyRequest asserts the mode's series are present on a
// service nobody has called yet, so an empty graph during a talk means a broken
// scrape config and never "no traffic yet".
func TestSeriesExistBeforeAnyRequest(t *testing.T) {
	_, h := New("unlocked")

	body := scrape(t, h)

	for _, series := range []string{
		`demo3_active_workers{mode="unlocked"} 0`,
		`demo3_mutex_wait_seconds_total{mode="unlocked"} 0`,
		`demo3_items_processed_total{mode="unlocked"} 0`,
	} {
		if !strings.Contains(body, series) {
			t.Errorf("/metrics does not pre-initialise %s", series)
		}
	}
}

// TestNewIsIndependentPerCall builds several Sets in one process, which is what
// the rest of this file does implicitly.
//
// Registering the Go and process collectors twice on the same registry panics, so
// a Set that reached for prometheus.DefaultRegisterer would make the second test
// in any run fail — and it would fail as a panic in an unrelated test, which is a
// miserable thing to debug. Asserting it here names the constraint.
func TestNewIsIndependentPerCall(t *testing.T) {
	for range 3 {
		s, h := New("locked")
		s.ObserveItems("locked", 1)
		if body := scrape(t, h); !strings.Contains(body, `demo3_items_processed_total{mode="locked"} 1`) {
			t.Fatal("each Set must own its registry; this one is sharing or empty")
		}
	}
}

// TestWorkerGaugeReturnsToZero asserts the gauge is balanced. A gauge that
// creeps is worse than no gauge: it turns "16 workers" into an artefact of how
// many requests have been served.
func TestWorkerGaugeReturnsToZero(t *testing.T) {
	s, _ := New("locked")

	var leave []func()
	for range 5 {
		leave = append(leave, s.WorkerEnter("locked"))
	}
	if got := gaugeValue(t, s, "demo3_active_workers"); got != 5 {
		t.Fatalf("demo3_active_workers = %v, want 5 while workers are inside", got)
	}
	for _, done := range leave {
		done()
	}
	if got := gaugeValue(t, s, "demo3_active_workers"); got != 0 {
		t.Fatalf("demo3_active_workers = %v after every worker left, want 0", got)
	}
}

// TestHistogramRecordsOnlySuccesses covers both halves of ObserveRequest: an
// "ok" batch is timed, and a cancelled one is counted but not timed.
func TestHistogramRecordsOnlySuccesses(t *testing.T) {
	s, _ := New("locked")

	s.ObserveRequest("locked", "ok", 0.25)
	s.ObserveRequest("locked", "cancelled", 9)

	h := histogram(t, s)
	if got := h.GetSampleCount(); got != 1 {
		t.Fatalf("histogram sample count = %d, want 1 (the cancelled batch must not be timed)", got)
	}
	if got := h.GetSampleSum(); got < 0.24 || got > 0.26 {
		t.Fatalf("histogram sum = %v, want ~0.25", got)
	}
	if got := counterValue(t, s, "demo3_requests_total", "cancelled"); got != 1 {
		t.Fatalf("cancelled requests = %v, want 1", got)
	}
}

// TestLockedModeAccumulatesMoreMutexWait runs both modes through the real work
// package with the metrics attached, and asserts the counter separates them.
//
// The assertion is deliberately a ratio and not a threshold in seconds: the
// absolute numbers depend on the machine, and a demo assertion that only holds on
// one laptop is not an assertion. Locked mode makes 15 of 16 tasks queue behind a
// full task's worth of work, so its total wait is orders of magnitude larger, not
// a few percent.
func TestLockedModeAccumulatesMoreMutexWait(t *testing.T) {
	const items, dur = 8, 10 * time.Millisecond

	locked, _ := New("locked")
	bs := work.NewStore()
	bs.Observe(locked)
	bs.RunLocked(context.Background(), work.Tasks(items, dur))
	lockedWait := counterValue(t, locked, "demo3_mutex_wait_seconds_total", "")

	unlocked, _ := New("unlocked")
	fs := work.NewStore()
	fs.Observe(unlocked)
	fs.RunUnlocked(context.Background(), work.Tasks(items, dur))
	unlockedWait := counterValue(t, unlocked, "demo3_mutex_wait_seconds_total", "")

	if lockedWait <= unlockedWait {
		t.Fatalf("locked mutex wait %vs is not above unlocked %vs — the demo has nothing to show", lockedWait, unlockedWait)
	}
	if lockedWait < 4*unlockedWait {
		t.Errorf("locked mutex wait %vs is only %.1fx unlocked %vs; expected the two to be far apart",
			lockedWait, lockedWait/unlockedWait, unlockedWait)
	}
}

// TestObservedRunLeavesNoWorkersBehind is the end-to-end version of the gauge
// test: after a real batch through the real work package, nothing is active.
// It also runs under -race, which is why the observer is loaded atomically.
func TestObservedRunLeavesNoWorkersBehind(t *testing.T) {
	for _, mode := range []string{"locked", "unlocked"} {
		t.Run(mode, func(t *testing.T) {
			s, _ := New(mode)
			store := work.NewStore()
			store.Observe(s)

			batch, err := store.Run(context.Background(), mode, work.Tasks(8, 5*time.Millisecond))
			if err != nil {
				t.Fatal(err)
			}
			if len(batch.Results) != 8 {
				t.Fatalf("got %d results, want 8", len(batch.Results))
			}
			if got := gaugeValue(t, s, "demo3_active_workers"); got != 0 {
				t.Fatalf("demo3_active_workers = %v after the batch finished, want 0", got)
			}
		})
	}
}

// TestNilObserverIsSafe asserts the work package still runs with no metrics
// attached, which is the state every test in internal/work runs in.
func TestNilObserverIsSafe(t *testing.T) {
	store := work.NewStore()
	if _, err := store.Run(context.Background(), "unlocked", work.Tasks(2, time.Millisecond)); err != nil {
		t.Fatal(err)
	}

	s, _ := New("unlocked")
	store.Observe(s)
	store.Observe(nil)
	if _, err := store.Run(context.Background(), "unlocked", work.Tasks(2, time.Millisecond)); err != nil {
		t.Fatal(err)
	}
}

// --- helpers ---------------------------------------------------------------

func scrape(t *testing.T, h http.Handler) string {
	t.Helper()

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("/metrics returned %d, want 200", rec.Code)
	}
	body, err := io.ReadAll(rec.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

// family gathers from the registry rather than parsing the exposition text: the
// numbers are then floats and not strings, and the test says what it means.
func family(t *testing.T, s *Set, name string) *dto.MetricFamily {
	t.Helper()

	got, err := s.Registry().Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, mf := range got {
		if mf.GetName() == name {
			return mf
		}
	}
	t.Fatalf("no metric family named %s", name)
	return nil
}

func gaugeValue(t *testing.T, s *Set, name string) float64 {
	t.Helper()
	return family(t, s, name).GetMetric()[0].GetGauge().GetValue()
}

// counterValue sums the family, optionally filtering by outcome. Summing keeps
// the helper usable for both the single-series counters and requests_total, which
// is split by outcome.
func counterValue(t *testing.T, s *Set, name, outcome string) float64 {
	t.Helper()

	var total float64
	for _, m := range family(t, s, name).GetMetric() {
		if outcome != "" && !hasLabel(m, "outcome", outcome) {
			continue
		}
		total += m.GetCounter().GetValue()
	}
	return total
}

func hasLabel(m *dto.Metric, name, value string) bool {
	for _, l := range m.GetLabel() {
		if l.GetName() == name && l.GetValue() == value {
			return true
		}
	}
	return false
}

func histogram(t *testing.T, s *Set) *dto.Histogram {
	t.Helper()
	return family(t, s, "demo3_request_duration_seconds").GetMetric()[0].GetHistogram()
}
