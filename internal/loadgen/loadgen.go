// Package loadgen is the deterministic load generator shared by all four demos.
//
// "Deterministic" here means: a fixed number of requests, a fixed concurrency,
// no random think time, and no ramp-up. Two runs against the same server
// produce comparable percentiles, which is what makes a before/after
// comparison on stage believable.
package loadgen

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

// Config describes one load run.
type Config struct {
	URL         string
	Method      string
	Body        string        // request body, replayed for every request
	ContentType string        // required when Body is non-empty
	Requests    int           // total requests across all workers
	Concurrency int           // number of concurrent workers
	Timeout     time.Duration // per-request timeout
	Warmup      int           // requests to send and discard before measuring
}

// Result is the outcome of one load run.
type Result struct {
	Config    Config
	Latencies []time.Duration // successful requests only, sorted ascending
	Errors    int
	Statuses  map[int]int
	Wall      time.Duration
}

// Run executes the load described by cfg.
//
// Every worker shares one http.Client, and therefore one connection pool, so
// that the client side does not become the bottleneck we are trying to measure
// on the server side. MaxConnsPerHost is deliberately set to the concurrency:
// a smaller pool would add client-side queueing to every measurement, which is
// exactly the kind of hidden wait demo 1 is about.
func Run(ctx context.Context, cfg Config) (*Result, error) {
	if cfg.Method == "" {
		cfg.Method = http.MethodGet
	}
	if cfg.Concurrency < 1 {
		cfg.Concurrency = 1
	}
	if cfg.Requests < 1 {
		cfg.Requests = 1
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 30 * time.Second
	}

	client := &http.Client{
		Timeout: cfg.Timeout,
		Transport: &http.Transport{
			MaxIdleConns:        cfg.Concurrency * 2,
			MaxIdleConnsPerHost: cfg.Concurrency * 2,
			MaxConnsPerHost:     cfg.Concurrency * 2,
			IdleConnTimeout:     90 * time.Second,
		},
	}
	defer client.CloseIdleConnections()

	if cfg.Warmup > 0 {
		warm := cfg.
			withCounts(cfg.Warmup, min(cfg.Concurrency, cfg.Warmup))
		drive(ctx, client, warm, nil)
	}

	res := &Result{
		Config:    cfg,
		Statuses:  map[int]int{},
		Latencies: make([]time.Duration, 0, cfg.Requests),
	}
	start := time.Now()
	drive(ctx, client, cfg, res)
	res.Wall = time.Since(start)
	sort.Slice(res.Latencies, func(i, j int) bool { return res.Latencies[i] < res.Latencies[j] })
	return res, nil
}

// drive sends cfg.Requests requests using cfg.Concurrency workers. When res is
// nil the results are discarded, which is how the warm-up phase runs.
func drive(ctx context.Context, client *http.Client, cfg Config, res *Result) {
	var (
		mu   sync.Mutex
		wg   sync.WaitGroup
		jobs = make(chan int)
	)

	for i := 0; i < cfg.Concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range jobs {
				lat, status, err := one(ctx, client, cfg)
				if res == nil {
					continue
				}
				mu.Lock()
				if err != nil {
					res.Errors++
				} else {
					res.Statuses[status]++
					res.Latencies = append(res.Latencies, lat)
				}
				mu.Unlock()
			}
		}()
	}

	for i := 0; i < cfg.Requests; i++ {
		select {
		case jobs <- i:
		case <-ctx.Done():
			close(jobs)
			wg.Wait()
			return
		}
	}
	close(jobs)
	wg.Wait()
}

func one(ctx context.Context, client *http.Client, cfg Config) (time.Duration, int, error) {
	var body io.Reader
	if cfg.Body != "" {
		body = strings.NewReader(cfg.Body)
	}
	req, err := http.NewRequestWithContext(ctx, cfg.Method, cfg.URL, body)
	if err != nil {
		return 0, 0, err
	}
	if cfg.ContentType != "" {
		req.Header.Set("Content-Type", cfg.ContentType)
	}

	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return 0, 0, err
	}
	// Drain the body before closing: a body that is closed without being read
	// prevents the connection from returning to the idle pool, which quietly
	// turns every request into a fresh TCP handshake.
	_, _ = io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	return time.Since(start), resp.StatusCode, nil
}

// Percentile returns the p-th percentile latency (p in 0..100) using
// nearest-rank on the sorted sample.
func (r *Result) Percentile(p float64) time.Duration {
	if len(r.Latencies) == 0 {
		return 0
	}
	idx := int(float64(len(r.Latencies)-1) * p / 100)
	return r.Latencies[idx]
}

// Mean returns the average successful-request latency.
func (r *Result) Mean() time.Duration {
	if len(r.Latencies) == 0 {
		return 0
	}
	var total time.Duration
	for _, d := range r.Latencies {
		total += d
	}
	return total / time.Duration(len(r.Latencies))
}

// Throughput returns completed successful requests per second.
func (r *Result) Throughput() float64 {
	if r.Wall <= 0 {
		return 0
	}
	return float64(len(r.Latencies)) / r.Wall.Seconds()
}

// String renders a fixed-width summary. The layout is stable on purpose: two
// runs printed one after the other on a projector should line up column-wise
// so the audience can compare without squinting.
func (r *Result) String() string {
	var b strings.Builder
	fmt.Fprintf(&b, "requests=%d concurrency=%d ok=%d errors=%d wall=%s\n",
		r.Config.Requests, r.Config.Concurrency, len(r.Latencies), r.Errors, r.Wall.Round(time.Millisecond))
	if len(r.Latencies) == 0 {
		b.WriteString("  no successful requests\n")
		return b.String()
	}
	fmt.Fprintf(&b, "  latency  min=%-8s avg=%-8s p50=%-8s p95=%-8s p99=%-8s max=%-8s\n",
		ms(r.Latencies[0]), ms(r.Mean()), ms(r.Percentile(50)), ms(r.Percentile(95)),
		ms(r.Percentile(99)), ms(r.Latencies[len(r.Latencies)-1]))
	fmt.Fprintf(&b, "  throughput %.1f req/s\n", r.Throughput())
	if len(r.Statuses) > 0 {
		codes := make([]int, 0, len(r.Statuses))
		for c := range r.Statuses {
			codes = append(codes, c)
		}
		sort.Ints(codes)
		fmt.Fprintf(&b, "  status")
		for _, c := range codes {
			fmt.Fprintf(&b, " %d=%d", c, r.Statuses[c])
		}
		b.WriteString("\n")
	}
	return b.String()
}

func ms(d time.Duration) string {
	return fmt.Sprintf("%.1fms", float64(d.Microseconds())/1000)
}

func (c Config) withCounts(requests, concurrency int) Config {
	c.Requests = requests
	c.Concurrency = concurrency
	return c
}
