// Command demo2-server serves GET /work, once with a goroutine leak and once
// without.
//
// The two handlers do the same work and answer the same requests. The only
// difference is what happens to the worker goroutine when the client goes away
// before the work is done — and that difference is invisible in a latency graph,
// invisible in an error rate, and plain in a goroutine profile.
//
//	:8081  GET /work
//	:6061  /metrics            go_goroutines — how many goroutines exist
//	:6061  /debug/pprof/*      the goroutine profile — what they are doing
//
// The two diagnostic endpoints answer different questions, and the demo needs
// both: the metric is what a dashboard would have alerted on, and the profile is
// what you open next. Neither substitutes for the other — a gauge cannot name a
// line, and nobody scrapes a profile every fifteen seconds.
//
// -pprof=false serves only /metrics, which is where most services actually are.
// The talk starts there deliberately: act 1 detects the leak with the metric and
// then gets stuck, because being stuck is the reason to reach for a profile.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	_ "net/http/pprof" // registers /debug/pprof/* on http.DefaultServeMux
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Result is what one unit of work produces.
type Result struct {
	Value string
}

var (
	addr      = flag.String("addr", ":8081", "application listen address")
	diagAddr  = flag.String("diag-addr", ":6061", "diagnostics listen address")
	mode      = flag.String("mode", "broken", "broken or fixed")
	withPprof = flag.Bool("pprof", true, "also serve /debug/pprof on the diagnostics listener")
	work      = flag.Duration("work", 90*time.Millisecond, "how long doWork takes")
)

func main() {
	flag.Parse()
	if *mode != "broken" && *mode != "fixed" {
		fmt.Fprintf(os.Stderr, "mode must be broken or fixed, got %q\n", *mode)
		os.Exit(2)
	}

	// Diagnostics on their own listener: they must stay answerable while :8081 is
	// busy, since the whole demo is asking them questions during load.
	if err := startDiagnosticsServer(*diagAddr); err != nil {
		fmt.Fprintf(os.Stderr, "diagnostics server: %v\n", err)
		os.Exit(1)
	}

	mux := http.NewServeMux()
	if *mode == "broken" {
		mux.HandleFunc("/work", handleWorkBroken)
	} else {
		mux.HandleFunc("/work", handleWorkFixed)
	}

	log.Printf("mode=%s app=%s diag=%s pprof=%t work=%s", *mode, *addr, *diagAddr, *withPprof, *work)
	log.Fatal(http.ListenAndServe(*addr, mux))
}

// Two versions of the diagnostics server, and both are in the source on purpose:
// the talk shows the diff between them, so the "before" has to be real code that
// really ran. -pprof picks one.
//
// This is the same arrangement demo 1 uses for its sequential and concurrent
// dashboard fetches. The duplicated registry block is the cost of being able to
// diff the two side by side, and it is a cost worth paying for the three lines it
// makes visible.

// diagnosticsMetrics serves metrics and nothing else — where most services are.
//
// Enough to be alerted. Not enough to find out why: go_goroutines will tell the
// room that goroutines are piling up and then have nothing further to say.
//
// The registry is a dedicated one, not prometheus.DefaultRegisterer. The default
// registry already has the Go and process collectors installed by client_golang's
// own init, so registering them again there would panic on a duplicate — and a
// private registry also means /metrics carries exactly the two collectors named
// here and nothing a future import might add.
func diagnosticsMetrics() *http.ServeMux {
	registry := prometheus.NewRegistry()
	registry.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(registry, promhttp.HandlerOpts{}))

	return mux
}

// diagnosticsProfiling serves the same metrics, plus the profiles.
//
// The whole change is the one Handle call at the end, and it is the difference
// between knowing a number is climbing and knowing which line it is stuck on.
func diagnosticsProfiling() *http.ServeMux {
	registry := prometheus.NewRegistry()
	registry.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(registry, promhttp.HandlerOpts{}))
	// net/http/pprof registers itself on DefaultServeMux, so delegating the whole
	// prefix is how /debug/pprof/* reaches it from a mux of our own.
	mux.Handle("/debug/pprof/", http.DefaultServeMux)

	return mux
}

// diagnosticsMux returns whichever of the two the -pprof flag asked for.
func diagnosticsMux() *http.ServeMux {
	if *withPprof {
		return diagnosticsProfiling()
	}
	return diagnosticsMetrics()
}

// startDiagnosticsServer binds addr and serves the diagnostics in the background.
//
// The bind happens here rather than inside the goroutine so that "port already in
// use" is a startup error the caller can act on. A background log.Fatal would kill
// the process from under a handler and print the reason where nobody is looking —
// on stage, that reads as "the demo hung".
func startDiagnosticsServer(addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}

	go func() {
		if err := http.Serve(ln, diagnosticsMux()); err != nil {
			log.Printf("diagnostics server stopped: %v", err)
		}
	}()

	return nil
}

// handleWorkBroken leaks one goroutine per cancelled request.
//
// Two mistakes, and it takes both to leak:
//
//  1. the worker is started with context.Background(), so cancelling the request
//     does not stop the work;
//  2. the send is not guarded by a select, so the worker parks on
//     `results <- result` forever once the handler has returned and nobody is
//     left to receive.
//
// The handler itself is correct and returns promptly on cancellation. That is
// what makes this hard to see from outside: latency is fine, the error rate is
// fine, and the process quietly accumulates goroutines that will never run again.
func handleWorkBroken(w http.ResponseWriter, r *http.Request) {
	results := make(chan Result)

	go func() {
		result := doWork(context.Background())
		results <- result // leaks: nobody receives after the handler returns
	}()

	select {
	case result := <-results:
		writeResult(w, result)
	case <-r.Context().Done():
		return
	}
}

// handleWorkFixed does the same thing and leaves nothing behind.
//
// Two changes, both about cancellation: the request context is passed to the
// worker so the work itself stops, and the send is in a select with ctx.Done()
// so the worker cannot park on it forever.
func handleWorkFixed(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	results := make(chan Result)

	go func() {
		result, err := doWorkCancellable(ctx)
		if err != nil {
			return
		}

		select {
		case results <- result:
		case <-ctx.Done():
			return
		}
	}()

	select {
	case result := <-results:
		writeResult(w, result)
	case <-ctx.Done():
		return
	}
}

// doWork is the broken worker: it ignores cancellation and always takes *work.
//
// It accepts a context and does nothing with it, which is exactly the shape of
// the bug in the wild — the parameter is there, the plumbing looks right, and
// time.Sleep cannot be interrupted by any of it. The blank name says so out loud
// rather than leaving a reader to check.
func doWork(_ context.Context) Result {
	time.Sleep(*work)
	return Result{Value: "done"}
}

// doWorkCancellable is the same work, cancellable. It returns early with
// ctx.Err() when the request goes away, so no time is spent on a result nobody
// will read.
func doWorkCancellable(ctx context.Context) (Result, error) {
	select {
	case <-time.After(*work):
		return Result{Value: "done"}, nil
	case <-ctx.Done():
		return Result{}, ctx.Err()
	}
}

func writeResult(w http.ResponseWriter, result Result) {
	fmt.Fprintln(w, result.Value)
}
