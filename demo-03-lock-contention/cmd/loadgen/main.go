// Command loadgen drives GET /compute.
//
// Concurrency defaults to 8, matching plan_v2's -concurrent-requests. That is
// what makes the contention a *process-wide* phenomenon rather than a
// per-request one: the mutex is shared, so eight concurrent requests of sixteen
// tasks each means 128 goroutines queued on one lock, and the mutex profile has
// something to accumulate.
//
// For a readable execution trace, drop to -concurrency 1. One request in flight
// at a time gives a timeline containing one batch instead of eight interleaved
// ones, which is much easier to read on a projector. Both are worth showing: the
// mutex profile wants load, the trace wants clarity.
package main

import (
	"flag"
	"fmt"
	"net/url"
	"strconv"

	"github.com/doniacld/go-observability-demos/internal/loadgen"
)

func main() {
	f := loadgen.Bind("http://localhost:8082/compute", 24, 8)
	items := flag.Int("items", 0, "override items per request (0 uses the server's default)")
	duration := flag.String("duration", "", "override CPU time per task, e.g. 50ms (empty uses the server's default)")
	flag.Parse()

	cfg := f.Config()

	// Query parameters rather than a body: /compute is a GET, and putting the
	// knobs in the URL means the exact request is copy-pasteable into curl.
	if *items > 0 || *duration != "" {
		u, err := url.Parse(cfg.URL)
		if err != nil {
			fmt.Printf("loadgen: bad -url %q: %v\n", cfg.URL, err)
			return
		}
		q := u.Query()
		if *items > 0 {
			q.Set("items", strconv.Itoa(*items))
		}
		if *duration != "" {
			q.Set("duration", *duration)
		}
		u.RawQuery = q.Encode()
		cfg.URL = u.String()
	}

	loadgen.Main(f, cfg)
}
