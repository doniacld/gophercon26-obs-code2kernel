package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/doniacld/go-observability-demos/demo-03-lock-contention/internal/metrics"
	"github.com/doniacld/go-observability-demos/demo-03-lock-contention/internal/work"
	"github.com/doniacld/go-observability-demos/internal/diag"
)

// newService assembles the same pieces main does, with a task duration small
// enough for a test.
func newService(t *testing.T, mode string) (*service, http.Handler, http.Handler) {
	t.Helper()

	store := work.NewStore()
	mset, mh := metrics.New(mode)
	store.Observe(mset)

	svc := &service{
		log:          slog.New(slog.NewTextHandler(io.Discard, nil)),
		store:        store,
		metrics:      mset,
		mode:         mode,
		workItems:    4,
		workDuration: 5 * time.Millisecond,
		maxItems:     512,
		maxDuration:  time.Second,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /compute", svc.compute)
	mux.HandleFunc("POST /process", svc.compute)
	return svc, mux, mh
}

// TestProcessAndComputeAreTheSameHandler asserts the endpoint the metrics
// dashboard names and the endpoint every existing make target calls behave
// identically — including producing the same checksums, since the two spellings
// must not be able to drift into two code paths.
func TestProcessAndComputeAreTheSameHandler(t *testing.T) {
	_, mux, _ := newService(t, "unlocked")

	get := decode(t, mux, httptest.NewRequest(http.MethodGet, "/compute", nil))
	post := decode(t, mux, httptest.NewRequest(http.MethodPost, "/process", nil))

	if got, want := post["mode"], "unlocked"; got != want {
		t.Errorf("POST /process mode = %v, want %v", got, want)
	}
	if got, want := post["items"], get["items"]; got != want {
		t.Errorf("POST /process items = %v, GET /compute items = %v", got, want)
	}
	sameChecksums(t, get, post)
}

// TestBothModesReturnTheSameResults is the correctness half of the demo: the fix
// changes the timing and nothing else. Asserted through the handler rather than
// only in internal/work, because the handler is what the audience drives.
func TestBothModesReturnTheSameResults(t *testing.T) {
	_, lockedMux, _ := newService(t, "locked")
	_, unlockedMux, _ := newService(t, "unlocked")

	locked := decode(t, lockedMux, httptest.NewRequest(http.MethodPost, "/process", nil))
	unlocked := decode(t, unlockedMux, httptest.NewRequest(http.MethodPost, "/process", nil))

	sameChecksums(t, locked, unlocked)
	if locked["peak_working"] != float64(1) {
		t.Errorf("locked peak_working = %v, want 1: the bug is not present", locked["peak_working"])
	}
}

// TestRequestsAreCounted asserts the handler feeds the metrics: the counter, the
// histogram and the item total all move for one request. Without this, an
// instrumented handler that silently stopped recording would still pass every
// other test in the package.
func TestRequestsAreCounted(t *testing.T) {
	_, mux, mh := newService(t, "locked")

	decode(t, mux, httptest.NewRequest(http.MethodPost, "/process", nil))

	body := scrape(t, mh)
	for _, series := range []string{
		`demo3_requests_total{mode="locked",outcome="ok"} 1`,
		`demo3_items_processed_total{mode="locked"} 4`,
		`demo3_request_duration_seconds_count{mode="locked"} 1`,
		`demo3_active_workers{mode="locked"} 0`,
	} {
		if !strings.Contains(body, series) {
			t.Errorf("/metrics does not contain %s\n%s", series, body)
		}
	}
}

// TestMetricsIsServedByTheDiagnosticsListener asserts the choice not to open a
// third port: /metrics answers on the same listener as pprof, and both are
// reachable at once.
func TestMetricsIsServedByTheDiagnosticsListener(t *testing.T) {
	_, _, mh := newService(t, "locked")

	// Port 0: the OS picks a free one, so the test cannot collide with a service
	// left running from a rehearsal.
	d := diag.New("127.0.0.1:0")
	d.Handle("/metrics", mh)
	if err := d.Start(); err != nil {
		t.Fatal(err)
	}

	for _, path := range []string{"/metrics", "/debug/pprof/"} {
		res, err := http.Get(d.URL(path))
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		_, _ = io.Copy(io.Discard, res.Body)
		_ = res.Body.Close()
		if res.StatusCode != http.StatusOK {
			t.Errorf("GET %s returned %d, want 200", path, res.StatusCode)
		}
	}

	// Clean shutdown, and asserted rather than deferred and ignored: a listener
	// that does not release :6062 makes the next `make after` fail to bind, which
	// on stage looks like the demo being locked.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := d.Shutdown(ctx); err != nil {
		t.Fatalf("diagnostics shutdown: %v", err)
	}
	if _, err := http.Get(d.URL("/metrics")); err == nil {
		t.Error("diagnostics listener still answering after Shutdown")
	}
}

// TestOversizedRequestsAreRejected covers the safety bound: the load generator
// and the Makefile both pass items explicitly, and a typo there must not turn a
// laptop into a space heater.
func TestOversizedRequestsAreRejected(t *testing.T) {
	svc, mux, _ := newService(t, "unlocked")
	svc.maxItems = 8

	for _, target := range []string{"/process?items=9", "/process?duration=2s", "/process?mode=sideways"} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, target, nil))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("POST %s returned %d, want 400", target, rec.Code)
		}
	}
}

// --- helpers ---------------------------------------------------------------

func decode(t *testing.T, h http.Handler, r *http.Request) map[string]any {
	t.Helper()

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, r)
	if rec.Code != http.StatusOK {
		t.Fatalf("%s %s returned %d: %s", r.Method, r.URL, rec.Code, rec.Body.String())
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decoding %s %s: %v", r.Method, r.URL, err)
	}
	return out
}

func sameChecksums(t *testing.T, a, b map[string]any) {
	t.Helper()

	x, _ := json.Marshal(a["checksum_head"])
	y, _ := json.Marshal(b["checksum_head"])
	if string(x) != string(y) {
		t.Errorf("checksums differ: %s vs %s", x, y)
	}
}

func scrape(t *testing.T, h http.Handler) string {
	t.Helper()

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("/metrics returned %d, want 200", rec.Code)
	}
	return rec.Body.String()
}
