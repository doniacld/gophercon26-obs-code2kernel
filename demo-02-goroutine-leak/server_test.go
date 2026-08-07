package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"testing"
	"time"
)

// The tests make the same claim the demo makes, without a projector: cancel a
// request mid-work and count what the process is left holding.
//
// runtime.NumGoroutine is the assertion rather than a pprof scrape, because a
// test should not need a listening socket to observe its own runtime. It is the
// same number the profile's "total" line reports.

func TestMain(m *testing.M) {
	// The handlers read *work, and flag defaults are not applied until the flags
	// are parsed. 20ms keeps the tests quick while leaving room for a client to
	// cancel first.
	short := 20 * time.Millisecond
	work = &short
	m.Run()
}

// countAfter returns how many goroutines the process gained by serving one
// cancelled request, once things have settled.
//
// The settle loop is not a fixed sleep: it waits for the count to stop moving,
// so the test is not a race between the assertion and a worker that is on its way
// out. A leaked goroutine never leaves, so a real leak survives any wait.
func countAfter(t *testing.T, h http.HandlerFunc) int {
	t.Helper()

	settle := func() int {
		last := -1
		for i := 0; i < 100; i++ {
			runtime.Gosched()
			time.Sleep(10 * time.Millisecond)
			if n := runtime.NumGoroutine(); n == last {
				return n
			} else {
				last = n
			}
		}
		return runtime.NumGoroutine()
	}

	before := settle()

	// Cancel while the work is still in flight, exactly as curl --max-time does.
	ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond)
	defer cancel()
	req := httptest.NewRequest(http.MethodGet, "/work", nil).WithContext(ctx)
	h(httptest.NewRecorder(), req)

	return settle() - before
}

// The bug: the worker outlives the request it was created for.
func TestBrokenLeaksOnCancellation(t *testing.T) {
	if got := countAfter(t, handleWorkBroken); got < 1 {
		t.Fatalf("expected the cancelled request to leak a goroutine, gained %d", got)
	}
}

// The fix: the same cancellation leaves nothing behind.
func TestFixedLeavesNothingBehind(t *testing.T) {
	if got := countAfter(t, handleWorkFixed); got != 0 {
		t.Fatalf("expected no goroutines to survive the cancelled request, gained %d", got)
	}
}

// Both handlers still answer a request that is allowed to finish. Without this,
// a handler that returned immediately and did no work at all would pass the two
// tests above.
func TestBothServeAnUncancelledRequest(t *testing.T) {
	for name, h := range map[string]http.HandlerFunc{
		"broken": handleWorkBroken,
		"fixed":  handleWorkFixed,
	} {
		t.Run(name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			h(rec, httptest.NewRequest(http.MethodGet, "/work", nil))
			if got, want := rec.Body.String(), "done\n"; got != want {
				t.Fatalf("body = %q, want %q", got, want)
			}
		})
	}
}

// The detection half of the demo: /metrics answers, and go_goroutines is in it.
//
// The value is not asserted. It is whatever the test binary happens to be running
// at the moment of the scrape, which is exactly why the demo compares two scrapes
// instead of trusting one.
func TestMetricsExposesGoGoroutines(t *testing.T) {
	rec := httptest.NewRecorder()
	diagnosticsMux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /metrics = %d, want %d", rec.Code, http.StatusOK)
	}
	body := rec.Body.String()
	for _, want := range []string{
		"# TYPE go_goroutines gauge",
		"\ngo_goroutines ",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("/metrics output is missing %q", want)
		}
	}
}

// The diagnosis half: the same listener still serves the goroutine profile, and
// it still reports goroutine states. Delegating /debug/pprof/ to DefaultServeMux
// is easy to get subtly wrong — a missing trailing slash serves a 404 — so this
// asserts on real profile content rather than only on the status code.
func TestDiagnosticsMuxServesPprof(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/debug/pprof/goroutine?debug=1", nil)
	diagnosticsMux().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /debug/pprof/goroutine = %d, want %d", rec.Code, http.StatusOK)
	}
	if got := rec.Body.String(); !strings.Contains(got, "goroutine profile: total ") {
		t.Errorf("profile output does not look like a goroutine profile: %.80q", got)
	}
}

// Building the mux twice must not panic. A collector registered on the default
// registry — which client_golang's init already populates — would, and the failure
// mode is a process that dies on startup rather than a test that fails here.
func TestDiagnosticsMuxRegistersWithoutPanicking(t *testing.T) {
	diagnosticsMux()
	diagnosticsMux()
}

// doWork ignores cancellation; doWorkCancellable honours it. This is the
// difference the fix rests on, asserted directly.
func TestCancellableWorkStopsEarly(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	start := time.Now()
	if _, err := doWorkCancellable(ctx); err == nil {
		t.Fatal("expected an error from an already-cancelled context")
	}
	if elapsed := time.Since(start); elapsed >= *work {
		t.Fatalf("doWorkCancellable took %s, expected it to return before %s", elapsed, *work)
	}
}
