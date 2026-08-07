package diag

import (
	"bytes"
	"fmt"
	"net/http"
	"runtime/trace"
	"sync"
	"time"
)

// FlightRecorder keeps a bounded window of the most recent execution-trace data
// in memory (runtime/trace.FlightRecorder, Go 1.25+) and writes a snapshot on
// demand.
//
// Why this matters for a live demo and for production: `go tool trace` needs a
// trace file, and a trace has to be running *before* the interesting thing
// happens. For a demo you can just start one. In production the problem is
// intermittent, so by the time you notice, the window has passed. A flight
// recorder keeps the last few seconds continuously, and you snapshot when
// something crosses a threshold.
type FlightRecorder struct {
	fr *trace.FlightRecorder

	mu   sync.Mutex
	last []byte
	at   time.Time
	n    int
}

// NewFlightRecorder starts a recorder retaining at least minAge of history,
// capped at maxBytes.
func NewFlightRecorder(minAge time.Duration, maxBytes uint64) (*FlightRecorder, error) {
	fr := trace.NewFlightRecorder(trace.FlightRecorderConfig{
		MinAge:   minAge,
		MaxBytes: maxBytes,
	})
	if err := fr.Start(); err != nil {
		return nil, fmt.Errorf("start flight recorder: %w", err)
	}
	return &FlightRecorder{fr: fr}, nil
}

// Stop stops the recorder.
func (f *FlightRecorder) Stop() {
	if f != nil && f.fr != nil {
		f.fr.Stop()
	}
}

// Snapshot captures the current window. It is safe to call concurrently; the
// most recent snapshot is retained so the HTTP endpoint can hand it out.
func (f *FlightRecorder) Snapshot() ([]byte, error) {
	var buf bytes.Buffer
	if _, err := f.fr.WriteTo(&buf); err != nil {
		return nil, err
	}
	b := buf.Bytes()
	f.mu.Lock()
	f.last, f.at, f.n = b, time.Now(), f.n+1
	f.mu.Unlock()
	return b, nil
}

// Handler serves the current window as a downloadable trace file:
//
//	curl -o trace.out http://localhost:6060/debug/flightrecorder
//	go tool trace trace.out
func (f *FlightRecorder) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		b, err := f.Snapshot()
		if err != nil {
			http.Error(w, fmt.Sprintf("snapshot: %v", err), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", `attachment; filename="flight.trace"`)
		w.Header().Set("X-Trace-Bytes", fmt.Sprint(len(b)))
		_, _ = w.Write(b)
	}
}

// LastSnapshot reports the size and time of the most recent snapshot.
func (f *FlightRecorder) LastSnapshot() (size int, at time.Time, count int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.last), f.at, f.n
}
