// Package diag serves the diagnostic endpoints on a listener separate from the
// application's own listener.
//
// Two listeners, not one, for two reasons. First, /debug/pprof must never be
// reachable from wherever the application port is reachable from — in
// production that separation is what lets you bind diagnostics to localhost or
// to an internal network only. Second, during a demo the application port is
// saturated with load; if pprof shared it, capturing a profile would queue
// behind the very requests you are trying to profile.
package diag

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/pprof"
	"os"
	"runtime"
	"time"
)

// Server is a diagnostics listener.
type Server struct {
	Addr string
	mux  *http.ServeMux
	srv  *http.Server
}

// New builds a diagnostics server exposing the standard net/http/pprof
// endpoints. Registering the handlers explicitly rather than relying on the
// import side effect keeps them off http.DefaultServeMux, so the application
// listener cannot accidentally serve them.
func New(addr string) *Server {
	mux := http.NewServeMux()

	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("/debug/runtime", runtimeInfo)

	return &Server{Addr: addr, mux: mux}
}

// Handle adds a custom diagnostic route, for example a flight-recorder
// snapshot endpoint.
func (s *Server) Handle(pattern string, h http.Handler) {
	s.mux.Handle(pattern, h)
}

// HandleFunc adds a custom diagnostic route.
func (s *Server) HandleFunc(pattern string, h http.HandlerFunc) {
	s.mux.HandleFunc(pattern, h)
}

// Start begins serving in a background goroutine. It returns only once the
// listener is bound, so a caller that prints "diagnostics ready" is telling the
// truth and a script that immediately curls the port will not race it.
func (s *Server) Start() error {
	ln, err := net.Listen("tcp", s.Addr)
	if err != nil {
		return fmt.Errorf("diag listen %s: %w", s.Addr, err)
	}
	s.Addr = ln.Addr().String()
	s.srv = &http.Server{
		Handler: s.mux,
		// No WriteTimeout: /debug/pprof/profile?seconds=30 and
		// /debug/pprof/trace?seconds=10 hold the response open for the whole
		// capture window, and a WriteTimeout would truncate them mid-profile.
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		if err := s.srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Fprintf(os.Stderr, "diag: %v\n", err)
		}
	}()
	return nil
}

// URL builds a copy-pasteable URL for a diagnostic path.
//
// net.Listener.Addr() on a wildcard bind returns "[::]:6062", and pasting
// "http://localhost[::]:6062" into a terminal gets you nothing but a puzzled
// curl. Keep only the port and say localhost.
func (s *Server) URL(path string) string {
	port := s.Addr
	if _, p, err := net.SplitHostPort(s.Addr); err == nil {
		port = p
	}
	if path != "" && path[0] != '/' {
		path = "/" + path
	}
	return fmt.Sprintf("http://localhost:%s%s", port, path)
}

// Shutdown stops the diagnostics listener.
func (s *Server) Shutdown(ctx context.Context) error {
	if s.srv == nil {
		return nil
	}
	return s.srv.Shutdown(ctx)
}

func runtimeInfo(w http.ResponseWriter, r *http.Request) {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	fmt.Fprintf(w, "go.version      %s\n", runtime.Version())
	fmt.Fprintf(w, "GOMAXPROCS      %d\n", runtime.GOMAXPROCS(0))
	fmt.Fprintf(w, "NumCPU          %d\n", runtime.NumCPU())
	fmt.Fprintf(w, "goroutines      %d\n", runtime.NumGoroutine())
	fmt.Fprintf(w, "heap.alloc      %d bytes\n", m.HeapAlloc)
	fmt.Fprintf(w, "heap.objects    %d\n", m.HeapObjects)
	fmt.Fprintf(w, "gc.cycles       %d\n", m.NumGC)
	fmt.Fprintf(w, "gc.pause.total  %s\n", time.Duration(m.PauseTotalNs))
}
