// Command frontend serves GET /dashboard by fetching three independent
// downstream services.
//
//	-mode broken  the three calls are made one after another  (~750ms)
//	-mode fixed   the three calls are made at the same time   (~320ms)
//
// Nothing is instrumented differently between the modes. Both produce the same
// spans with the same names and the same attributes; only their arrangement on
// the timeline changes. That is what makes this a control-flow bug rather than
// an instrumentation bug, and it is why the trace can diagnose it: a waterfall
// shows you the shape of execution, and the shape here is a staircase.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"

	"github.com/doniacld/go-observability-demos/demo-01-otel-sequential-calls/internal/dashboard"
	"github.com/doniacld/go-observability-demos/demo-01-otel-sequential-calls/internal/telemetry"
	"github.com/doniacld/go-observability-demos/internal/diag"
	"github.com/doniacld/go-observability-demos/internal/httpsrv"
)

const version = "1.0.0"

func main() {
	var (
		addr     = flag.String("addr", ":8080", "application listen address")
		diagAddr = flag.String("diag-addr", ":6060", "diagnostics listen address (pprof)")
		mode     = flag.String("mode", "broken", "broken|fixed — sequential or concurrent downstream calls")
		profile  = flag.String("profile-url", "http://localhost:8085/fetch", "profile-service URL")
		recs     = flag.String("recommendation-url", "http://localhost:8086/fetch", "recommendation-service URL")
		invent   = flag.String("inventory-url", "http://localhost:8087/fetch", "inventory-service URL")
		timeout  = flag.Duration("timeout", 5*time.Second, "per-request timeout for the whole dashboard")
		otlp     = flag.String("otlp-endpoint", "", "OTLP/HTTP endpoint host:port (default localhost:4318)")
	)
	flag.Parse()

	if *mode != "broken" && *mode != "fixed" {
		fmt.Fprintf(os.Stderr, "frontend: -mode must be broken or fixed, got %q\n", *mode)
		os.Exit(2)
	}

	log := slog.New(slog.NewTextHandler(os.Stdout, nil))

	shutdown, err := telemetry.Setup(telemetry.Config{
		ServiceName: "frontend",
		Version:     version,
		Endpoint:    *otlp,
		Mode:        *mode,
	})
	if err != nil {
		log.Error("telemetry setup failed", "error", err)
		os.Exit(1)
	}
	defer telemetry.Flush(shutdown, log)

	deps := []dashboard.Dependency{
		{Name: "profile-service", URL: *profile},
		{Name: "recommendation-service", URL: *recs},
		{Name: "inventory-service", URL: *invent},
	}

	fe := &frontend{
		log:  log,
		mode: *mode,
		client: &dashboard.Client{
			// otelhttp.NewTransport injects the traceparent header, which is what
			// makes the downstream server spans children of this request rather
			// than three unrelated traces.
			HTTP: &http.Client{
				Transport: otelhttp.NewTransport(http.DefaultTransport),
				Timeout:   *timeout,
			},
			Dependencies: deps,
			Mode:         *mode,
		},
	}

	mux := http.NewServeMux()
	mux.Handle("/dashboard", otelhttp.NewHandler(http.HandlerFunc(fe.dashboard), "GET /dashboard"))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	dsrv := diag.New(*diagAddr)
	if err := dsrv.Start(); err != nil {
		log.Error("diagnostics listener failed", "error", err)
		os.Exit(1)
	}

	names := make([]string, len(deps))
	for i, d := range deps {
		names[i] = d.Name
	}

	err = httpsrv.Run(*addr, mux, func(bound string) {
		log.Info("demo 1 frontend ready",
			"demo", 1,
			"mode", *mode,
			"addr", bound,
			"diag", dsrv.Addr,
			"dependencies", strings.Join(names, ","),
			"timeout", *timeout,
			"otlp", telemetry.Endpoint(*otlp),
		)
		if *mode == "broken" {
			log.Warn("MODE=broken — three independent calls made sequentially; latency is their sum")
		} else {
			log.Info("MODE=fixed — three independent calls made concurrently; latency is the slowest one")
		}
	})
	if err != nil {
		log.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

type frontend struct {
	log    *slog.Logger
	mode   string
	client *dashboard.Client
}

// dashboard handles GET /dashboard.
//
// The mode switch is the entire difference between the two builds. Everything
// around it — the span, the attributes, the response shape — is identical, so a
// trace from either build is directly comparable with the other.
func (f *frontend) dashboard(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	span := trace.SpanFromContext(ctx)
	span.SetAttributes(
		attribute.String("demo.mode", f.mode),
		attribute.String("http.route", "/dashboard"),
		attribute.String("service.version", version),
	)

	var (
		resp *dashboard.Response
		err  error
	)
	if f.mode == "broken" {
		resp, err = f.client.Sequential(ctx)
	} else {
		resp, err = f.client.Concurrent(ctx)
	}
	if err != nil {
		// One failed dependency fails the dashboard. That is a policy choice, and
		// stating it is part of the fix: errgroup makes "first error wins, siblings
		// are cancelled" the default, which is usually what you want for data a
		// page cannot render without.
		span.RecordError(err)
		span.SetStatus(codes.Error, "dependency failed")
		f.log.Error("dashboard failed", "mode", f.mode, "error", err)
		http.Error(w, "dependency failed: "+err.Error(), http.StatusBadGateway)
		return
	}

	// The two numbers that turn the waterfall into arithmetic. In broken mode
	// total_ms tracks sum_of_dependency_ms; in fixed mode it tracks
	// slowest_dependency_ms. The audience can verify the diagnosis from the
	// response body alone, without reading the trace at all.
	span.SetAttributes(
		attribute.Int64("dashboard.total_ms", int64(resp.TotalMS)),
		attribute.Int64("dashboard.sum_of_dependency_ms", int64(resp.SumOfMS)),
		attribute.Int64("dashboard.slowest_dependency_ms", int64(resp.SlowestMS)),
		attribute.String("dashboard.strategy", resp.Strategy),
	)

	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(resp)
}
