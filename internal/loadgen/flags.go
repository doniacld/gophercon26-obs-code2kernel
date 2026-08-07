package loadgen

import (
	"context"
	"flag"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"time"
)

// Flags binds a standard set of load-generator flags so that all four demos
// take the same command line. Call Parse after flag.Parse.
type Flags struct {
	URL         *string
	Method      *string
	Requests    *int
	Concurrency *int
	Timeout     *time.Duration
	Warmup      *int
	Wait        *time.Duration
}

// Bind registers the flags on the default flag set.
func Bind(defaultURL string, defaultRequests, defaultConcurrency int) *Flags {
	return &Flags{
		URL:         flag.String("url", defaultURL, "target URL"),
		Method:      flag.String("method", http.MethodGet, "HTTP method"),
		Requests:    flag.Int("requests", defaultRequests, "total number of requests"),
		Concurrency: flag.Int("concurrency", defaultConcurrency, "concurrent workers"),
		Timeout:     flag.Duration("timeout", 30*time.Second, "per-request timeout"),
		Warmup:      flag.Int("warmup", 0, "requests to send and discard before measuring"),
		Wait:        flag.Duration("wait", 20*time.Second, "how long to wait for the target to accept connections (0 disables)"),
	}
}

// Config turns the parsed flags into a Config.
func (f *Flags) Config() Config {
	return Config{
		URL:         *f.URL,
		Method:      *f.Method,
		Requests:    *f.Requests,
		Concurrency: *f.Concurrency,
		Timeout:     *f.Timeout,
		Warmup:      *f.Warmup,
	}
}

// WaitForTarget blocks until the host:port in the target URL accepts a TCP
// connection, or the deadline expires.
//
// This replaces the `sleep 2` that every demo script would otherwise need. A
// readiness check is not just tidier: a fixed sleep either wastes stage time or
// races the server, and on a cold laptop it usually does both.
func WaitForTarget(ctx context.Context, rawURL string, timeout time.Duration) error {
	if timeout <= 0 {
		return nil
	}
	u, err := url.Parse(rawURL)
	if err != nil {
		return err
	}
	addr := u.Host
	if u.Port() == "" {
		if u.Scheme == "https" {
			addr = net.JoinHostPort(u.Hostname(), "443")
		} else {
			addr = net.JoinHostPort(u.Hostname(), "80")
		}
	}

	deadline := time.Now().Add(timeout)
	for {
		conn, err := net.DialTimeout("tcp", addr, 500*time.Millisecond)
		if err == nil {
			conn.Close()
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("target %s not reachable after %s: %w", addr, timeout, err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
}

// Main is the whole body of every cmd/loadgen in this repository: wait for the
// target, run the load, print the summary, exit non-zero on failure.
func Main(f *Flags, cfg Config) {
	ctx := context.Background()
	if err := WaitForTarget(ctx, cfg.URL, *f.Wait); err != nil {
		fmt.Fprintf(os.Stderr, "loadgen: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("loadgen: %s %s requests=%d concurrency=%d\n",
		cfg.Method, cfg.URL, cfg.Requests, cfg.Concurrency)

	res, err := Run(ctx, cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "loadgen: %v\n", err)
		os.Exit(1)
	}
	fmt.Print(res)

	if len(res.Latencies) == 0 {
		os.Exit(1)
	}
}
