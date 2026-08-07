package dashboard

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// latencies used by the fake dependencies. Scaled down from the real 180/250/320
// so the tests stay fast, but the ratios are preserved: the sum is 3.75x the
// slowest, which is the margin the demo depends on.
const (
	profileLatency = 30 * time.Millisecond
	recsLatency    = 40 * time.Millisecond
	inventLatency  = 50 * time.Millisecond
	sumLatency     = profileLatency + recsLatency + inventLatency
)

// newFakeDeps starts three servers with the demo's latency profile and returns a
// client plus a counter of the maximum number of simultaneous in-flight calls.
func newFakeDeps(t *testing.T, mode string) (*Client, *int64) {
	t.Helper()

	var inFlight, maxInFlight int64
	handler := func(d time.Duration) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			cur := atomic.AddInt64(&inFlight, 1)
			for {
				old := atomic.LoadInt64(&maxInFlight)
				if cur <= old || atomic.CompareAndSwapInt64(&maxInFlight, old, cur) {
					break
				}
			}
			defer atomic.AddInt64(&inFlight, -1)

			select {
			case <-time.After(d):
			case <-r.Context().Done():
				w.WriteHeader(http.StatusRequestTimeout)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
		}
	}

	specs := []struct {
		name string
		d    time.Duration
	}{
		{"profile-service", profileLatency},
		{"recommendation-service", recsLatency},
		{"inventory-service", inventLatency},
	}

	deps := make([]Dependency, 0, len(specs))
	for _, s := range specs {
		srv := httptest.NewServer(handler(s.d))
		t.Cleanup(srv.Close)
		deps = append(deps, Dependency{Name: s.name, URL: srv.URL})
	}

	// A dedicated transport per client, with a connection pool large enough for
	// all three dependencies at once. The default transport's per-host limits are
	// irrelevant here (three different hosts), but an explicit pool makes it
	// impossible for client-side queueing to be mistaken for the serialization
	// the test is measuring.
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			MaxIdleConns:        len(deps) * 2,
			MaxIdleConnsPerHost: 2,
			MaxConnsPerHost:     2,
		},
	}
	t.Cleanup(client.CloseIdleConnections)

	return &Client{HTTP: client, Dependencies: deps, Mode: mode}, &maxInFlight
}

// TestBothModesReturnTheSameData is the equivalence check: the fix must not
// change the answer, only when the answer arrives. Without this, "faster" could
// quietly mean "does less work".
func TestBothModesReturnTheSameData(t *testing.T) {
	seqClient, _ := newFakeDeps(t, "broken")
	conClient, _ := newFakeDeps(t, "fixed")

	seq, err := seqClient.Sequential(context.Background())
	if err != nil {
		t.Fatalf("Sequential: %v", err)
	}
	con, err := conClient.Concurrent(context.Background())
	if err != nil {
		t.Fatalf("Concurrent: %v", err)
	}

	if len(seq.Results) != len(con.Results) {
		t.Fatalf("result count differs: %d vs %d", len(seq.Results), len(con.Results))
	}
	for i := range seq.Results {
		if seq.Results[i].Dependency != con.Results[i].Dependency {
			t.Errorf("result %d: dependency %q vs %q — order must be preserved",
				i, seq.Results[i].Dependency, con.Results[i].Dependency)
		}
		if string(seq.Results[i].Body) != string(con.Results[i].Body) {
			t.Errorf("result %d: body differs", i)
		}
	}
}

// TestConcurrentIsFasterThanSequential asserts the headline claim with a margin
// wide enough that a loaded CI machine does not fail it: sequential must take at
// least the sum, concurrent must take well under it.
func TestConcurrentIsFasterThanSequential(t *testing.T) {
	seqClient, seqMax := newFakeDeps(t, "broken")
	conClient, conMax := newFakeDeps(t, "fixed")

	start := time.Now()
	if _, err := seqClient.Sequential(context.Background()); err != nil {
		t.Fatalf("Sequential: %v", err)
	}
	seqWall := time.Since(start)

	start = time.Now()
	if _, err := conClient.Concurrent(context.Background()); err != nil {
		t.Fatalf("Concurrent: %v", err)
	}
	conWall := time.Since(start)

	if seqWall < sumLatency {
		t.Errorf("sequential took %s, expected at least the sum %s", seqWall, sumLatency)
	}
	// The slowest dependency is 50ms and the sum is 120ms; 90ms leaves room for
	// scheduling noise while still failing if the calls are serialized.
	if conWall > 90*time.Millisecond {
		t.Errorf("concurrent took %s, expected well under the sum %s", conWall, sumLatency)
	}
	if conWall >= seqWall {
		t.Errorf("concurrent (%s) was not faster than sequential (%s)", conWall, seqWall)
	}

	// The mechanism, not just the outcome: sequential must never have two calls
	// in flight, concurrent must reach all three.
	if got := *seqMax; got != 1 {
		t.Errorf("sequential peak in-flight = %d, want 1", got)
	}
	if got := *conMax; got != 3 {
		t.Errorf("concurrent peak in-flight = %d, want 3", got)
	}
}

// TestConcurrentCancelsSiblingsOnFailure covers the part of the fix that is easy
// to leave out: when one dependency fails, the others must be told to stop.
func TestConcurrentCancelsSiblingsOnFailure(t *testing.T) {
	var slowCancelled atomic.Bool

	failing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer failing.Close()

	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(2 * time.Second):
			_, _ = w.Write([]byte(`{"ok":true}`))
		case <-r.Context().Done():
			slowCancelled.Store(true)
		}
	}))
	defer slow.Close()

	c := &Client{
		HTTP: http.DefaultClient,
		Dependencies: []Dependency{
			{Name: "failing-service", URL: failing.URL},
			{Name: "slow-service", URL: slow.URL},
		},
		Mode: "fixed",
	}

	start := time.Now()
	_, err := c.Concurrent(context.Background())
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("Concurrent returned nil error when a dependency failed")
	}
	// Returning before the slow dependency's 2s is the observable proof that the
	// group cancelled rather than waited.
	if elapsed > time.Second {
		t.Errorf("Concurrent took %s — it waited for the slow sibling instead of cancelling it", elapsed)
	}
	// Give the cancelled handler a moment to record that it was cancelled.
	deadline := time.Now().Add(time.Second)
	for !slowCancelled.Load() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !slowCancelled.Load() {
		t.Error("the slow dependency was never cancelled")
	}
}

// TestSequentialStopsAtTheFirstError documents broken mode's behaviour so the
// comparison in the README is accurate: it also fails fast, but for the trivial
// reason that it had not started the other calls yet.
func TestSequentialStopsAtTheFirstError(t *testing.T) {
	var secondCalled atomic.Bool

	failing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer failing.Close()
	second := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		secondCalled.Store(true)
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer second.Close()

	c := &Client{
		HTTP: http.DefaultClient,
		Dependencies: []Dependency{
			{Name: "failing-service", URL: failing.URL},
			{Name: "second-service", URL: second.URL},
		},
		Mode: "broken",
	}

	if _, err := c.Sequential(context.Background()); err == nil {
		t.Fatal("Sequential returned nil error when the first dependency failed")
	}
	if secondCalled.Load() {
		t.Error("Sequential called the second dependency after the first failed")
	}
}

// TestResponseArithmetic checks the two numbers the speaker reads out loud.
func TestResponseArithmetic(t *testing.T) {
	seqClient, _ := newFakeDeps(t, "broken")
	conClient, _ := newFakeDeps(t, "fixed")

	seq, err := seqClient.Sequential(context.Background())
	if err != nil {
		t.Fatalf("Sequential: %v", err)
	}
	con, err := conClient.Concurrent(context.Background())
	if err != nil {
		t.Fatalf("Concurrent: %v", err)
	}

	// Sequential: total tracks the sum. Concurrent: total tracks the slowest.
	if seq.TotalMS < seq.SumOfMS*0.9 {
		t.Errorf("sequential total %.1fms is below the sum %.1fms", seq.TotalMS, seq.SumOfMS)
	}
	if con.TotalMS > con.SlowestMS*1.5 {
		t.Errorf("concurrent total %.1fms exceeds 1.5x the slowest %.1fms", con.TotalMS, con.SlowestMS)
	}
	if con.TotalMS > seq.TotalMS {
		t.Errorf("concurrent total %.1fms is not below sequential %.1fms", con.TotalMS, seq.TotalMS)
	}
}

// TestContextCancellationPropagates verifies both strategies honour a cancelled
// request context rather than running to completion for a client that has gone.
func TestContextCancellationPropagates(t *testing.T) {
	for _, mode := range []string{"broken", "fixed"} {
		t.Run(mode, func(t *testing.T) {
			c, _ := newFakeDeps(t, mode)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
			defer cancel()

			var err error
			if mode == "broken" {
				_, err = c.Sequential(ctx)
			} else {
				_, err = c.Concurrent(ctx)
			}
			if err == nil {
				t.Fatal("expected an error from a cancelled context")
			}
			// http.Client wraps the context error in a *url.Error, and fetch wraps
			// that again with the dependency name, so check the chain rather than
			// the top-level value.
			if !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled) {
				t.Errorf("error %v is not a context error", err)
			}
		})
	}
}
