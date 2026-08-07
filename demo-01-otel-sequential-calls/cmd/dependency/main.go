// Command dependency is one of the frontend's three downstream services.
//
// The same binary serves as profile-service, recommendation-service and
// inventory-service; only -name, -addr and -latency differ. One binary rather
// than three keeps the demo honest: the three services are deliberately
// identical apart from how long they take, so any difference the audience sees
// in the trace comes from the frontend's control flow and nothing else.
//
// The latency is a fixed sleep, not a computation. This service is not the
// subject of the demo — it is a stand-in for a real dependency whose duration
// you do not control, and a sleep is the most deterministic way to spend a
// known amount of wall-clock time.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"github.com/doniacld/go-observability-demos/demo-01-otel-sequential-calls/internal/telemetry"
	"github.com/doniacld/go-observability-demos/internal/httpsrv"
)

const version = "1.0.0"

func main() {
	var (
		addr    = flag.String("addr", ":8085", "listen address")
		name    = flag.String("name", "profile-service", "service name reported to OpenTelemetry")
		latency = flag.Duration("latency", 180*time.Millisecond, "deterministic response latency")
		mode    = flag.String("mode", "broken", "broken|fixed — recorded as demo.mode, behaviour is identical")
		otlp    = flag.String("otlp-endpoint", "", "OTLP/HTTP endpoint host:port (default localhost:4318)")
	)
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stdout, nil))

	shutdown, err := telemetry.Setup(telemetry.Config{
		ServiceName: *name,
		Version:     version,
		Endpoint:    *otlp,
		Mode:        *mode,
	})
	if err != nil {
		log.Error("telemetry setup failed", "error", err)
		os.Exit(1)
	}
	defer telemetry.Flush(shutdown, log)

	d := &dependency{name: *name, latency: *latency, mode: *mode}

	mux := http.NewServeMux()
	// The route pattern, not the request path, is the span name: "GET /fetch"
	// aggregates, whereas "GET /fetch?id=8f21..." would produce one distinct
	// operation name per request and make the service unfindable in Jaeger's
	// operation list.
	mux.Handle("/fetch", otelhttp.NewHandler(http.HandlerFunc(d.fetch), "GET /fetch"))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	err = httpsrv.Run(*addr, mux, func(bound string) {
		log.Info("demo 1 dependency ready",
			"demo", 1,
			"service", *name,
			"mode", *mode,
			"addr", bound,
			"latency", d.latency,
			"otlp", telemetry.Endpoint(*otlp),
		)
	})
	if err != nil {
		log.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

type dependency struct {
	name    string
	latency time.Duration
	mode    string
}

// fetch sleeps for the configured latency and returns a small payload.
//
// The work is wrapped in its own child span so the trace shows where the time
// went inside the service rather than only that the service was slow. In a real
// dependency this span would be the database query or the cache lookup.
func (d *dependency) fetch(w http.ResponseWriter, r *http.Request) {
	ctx, span := telemetry.Tracer().Start(r.Context(), d.name+".query",
		trace.WithAttributes(
			attribute.String("dependency.name", d.name),
			attribute.String("demo.mode", d.mode),
			attribute.Int64("dependency.latency_ms", d.latency.Milliseconds()),
		),
	)
	defer span.End()

	// Respect cancellation. In demo 1's fixed mode errgroup cancels the sibling
	// calls when one fails, and a dependency that ignored ctx would keep working
	// on a response nobody will read.
	select {
	case <-time.After(d.latency):
	case <-ctx.Done():
		span.SetAttributes(attribute.Bool("dependency.cancelled", true))
		http.Error(w, "cancelled", http.StatusRequestTimeout)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"dependency": d.name,
		"latency_ms": d.latency.Milliseconds(),
		"payload":    d.payload(),
	})
}

// payload returns a small deterministic body per dependency, so the frontend's
// response looks like an assembled dashboard rather than three copies of "ok".
func (d *dependency) payload() any {
	switch d.name {
	case "profile-service":
		return map[string]any{"user_id": 4711, "tier": "gold", "locale": "fr-FR"}
	case "recommendation-service":
		return map[string]any{"items": []string{"go-in-action", "systems-performance", "bpf-tools"}}
	case "inventory-service":
		return map[string]any{"in_stock": 3, "warehouse": "eu-west-1", "reserved": 1}
	default:
		return map[string]any{"ok": true}
	}
}
