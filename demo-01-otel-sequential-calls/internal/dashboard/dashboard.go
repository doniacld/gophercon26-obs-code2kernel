// Package dashboard assembles one dashboard response from three independent
// downstream services, twice: once sequentially, once concurrently.
//
// The two functions do exactly the same work and issue exactly the same three
// HTTP requests. The only difference is whether the second request waits for the
// first to finish. That difference is invisible in the source at a glance, plain
// in a trace waterfall, and worth roughly 400 ms per request.
package dashboard

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
	"golang.org/x/sync/errgroup"

	"github.com/doniacld/go-observability-demos/demo-01-otel-sequential-calls/internal/telemetry"
)

// Dependency is one downstream service the dashboard needs.
type Dependency struct {
	Name string // profile-service, recommendation-service, inventory-service
	URL  string
}

// Result is one dependency's contribution to the dashboard.
type Result struct {
	Dependency string          `json:"dependency"`
	Elapsed    time.Duration   `json:"-"`
	ElapsedMS  float64         `json:"elapsed_ms"`
	Body       json.RawMessage `json:"body,omitempty"`
}

// Response is what the frontend returns.
type Response struct {
	Mode      string   `json:"mode"`
	Strategy  string   `json:"strategy"`
	TotalMS   float64  `json:"total_ms"`
	SumOfMS   float64  `json:"sum_of_dependency_ms"`
	SlowestMS float64  `json:"slowest_dependency_ms"`
	Results   []Result `json:"results"`
}

// Client fetches from the dependencies.
type Client struct {
	HTTP         *http.Client
	Dependencies []Dependency
	Mode         string
}

// Sequential fetches each dependency in turn — the bug.
//
// Read the loop and note what is missing: nothing. There is no lock, no shared
// state, no ordering requirement between the three calls. The second call waits
// for the first purely because it is written on the next line, and that is
// enough to make end-to-end latency the sum of all three.
//
// This is the most common performance bug in service code, and it survives code
// review because a loop over dependencies is exactly what the problem looks
// like when you describe it in words.
func (c *Client) Sequential(ctx context.Context) (*Response, error) {
	start := time.Now()
	results := make([]Result, len(c.Dependencies))

	for i, dep := range c.Dependencies {
		res, err := c.fetch(ctx, dep)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", dep.Name, err)
		}
		results[i] = res
	}

	return c.response("sequential", results, time.Since(start)), nil
}

// Concurrent fetches every dependency at once — the fix.
//
// errgroup.WithContext gives three things a bare WaitGroup does not:
//
//  1. the first non-nil error is returned, so a failing dependency surfaces as a
//     failing request instead of a zero value in the response;
//  2. the derived context is cancelled as soon as any call fails, so the
//     siblings stop rather than finishing work whose result is already useless;
//  3. Wait blocks until every goroutine has returned, so there is no goroutine
//     still writing to results after this function returns — which is what makes
//     the unsynchronised writes to distinct slice slots safe.
//
// Each goroutine writes results[i] and nothing else. Distinct indices in a
// preallocated slice are independent memory, so no mutex is needed; every test in
// this package runs under -race to confirm it.
func (c *Client) Concurrent(ctx context.Context) (*Response, error) {
	start := time.Now()
	results := make([]Result, len(c.Dependencies))

	g, gctx := errgroup.WithContext(ctx)
	for i, dep := range c.Dependencies {
		g.Go(func() error {
			res, err := c.fetch(gctx, dep)
			if err != nil {
				return fmt.Errorf("%s: %w", dep.Name, err)
			}
			results[i] = res
			return nil
		})
	}
	if err := g.Wait(); err != nil {
		return nil, err
	}

	return c.response("concurrent", results, time.Since(start)), nil
}

// fetch performs one downstream call inside its own span.
//
// otelhttp.NewTransport already creates a client span for the HTTP request. The
// extra span here is worth its cost because it names the *dependency* rather
// than the URL: in the waterfall the audience reads "fetch profile-service", not
// "HTTP GET". Naming things after what they mean is most of what makes a trace
// readable at a glance from six rows back.
func (c *Client) fetch(ctx context.Context, dep Dependency) (Result, error) {
	ctx, span := telemetry.Tracer().Start(ctx, "fetch "+dep.Name,
		trace.WithAttributes(
			// dependency.name is low cardinality — three values, fixed by
			// configuration — so it is safe to index and useful to group by.
			attribute.String("dependency.name", dep.Name),
			attribute.String("demo.mode", c.Mode),
		),
	)
	defer span.End()

	start := time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, dep.URL, nil)
	if err != nil {
		return Result{}, err
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "downstream call failed")
		return Result{}, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "reading downstream response failed")
		return Result{}, err
	}
	if resp.StatusCode != http.StatusOK {
		err := fmt.Errorf("status %s", resp.Status)
		span.RecordError(err)
		span.SetStatus(codes.Error, "downstream returned an error")
		return Result{}, err
	}

	elapsed := time.Since(start)
	span.SetAttributes(attribute.Int64("dependency.elapsed_ms", elapsed.Milliseconds()))

	return Result{
		Dependency: dep.Name,
		Elapsed:    elapsed,
		ElapsedMS:  msFloat(elapsed),
		Body:       json.RawMessage(body),
	}, nil
}

// response computes the two numbers that make the bug arithmetic rather than
// anecdotal: the sum of the dependency latencies (what sequential costs) and the
// slowest one (what concurrent costs).
func (c *Client) response(strategy string, results []Result, total time.Duration) *Response {
	var sum, slowest time.Duration
	for _, r := range results {
		sum += r.Elapsed
		if r.Elapsed > slowest {
			slowest = r.Elapsed
		}
	}
	return &Response{
		Mode:      c.Mode,
		Strategy:  strategy,
		TotalMS:   msFloat(total),
		SumOfMS:   msFloat(sum),
		SlowestMS: msFloat(slowest),
		Results:   results,
	}
}

func msFloat(d time.Duration) float64 {
	return float64(d.Microseconds()) / 1000
}
