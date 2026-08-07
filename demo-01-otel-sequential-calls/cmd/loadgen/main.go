// Command loadgen drives GET /dashboard.
//
// The defaults match the plan's suggested invocation: 20 requests at concurrency
// 5. That is deliberately modest — this demo's evidence is the shape of a single
// trace, not a throughput number, and 20 requests is enough to have several
// traces to choose from in Jaeger without burying the interesting one.
//
// Expected, with dependencies at 180/250/320 ms:
//
//	broken  p50 ~755ms   (180 + 250 + 320, plus HTTP overhead)
//	fixed   p50 ~325ms   (the slowest dependency alone)
package main

import (
	"flag"

	"github.com/doniacld/go-observability-demos/internal/loadgen"
)

func main() {
	f := loadgen.Bind("http://localhost:8080/dashboard", 20, 5)
	flag.Parse()
	loadgen.Main(f, f.Config())
}
