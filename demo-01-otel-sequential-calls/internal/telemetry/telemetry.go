// Package telemetry sets up the OpenTelemetry tracing pipeline for demo 1.
//
// Everything here is ordinary OTel Go boilerplate except the sampler, which is
// AlwaysSample. That is correct for a demo and wrong for production: in
// production you sample, and the sampling decision should be made at the start
// of the trace and propagated, so that a trace is either kept whole or dropped
// whole. See the README section "Sampling" for why a per-service decision
// produces broken traces.
package telemetry

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	// The semconv version must match the one resource.Default() was built
	// against, or resource.Merge fails with "conflicting Schema URL". This is
	// pinned deliberately: bumping the otel SDK can require bumping this line.
	semconv "go.opentelemetry.io/otel/semconv/v1.41.0"
	"go.opentelemetry.io/otel/trace"
)

// DefaultEndpoint is where Jaeger's OTLP/HTTP receiver listens in this
// repository's docker-compose.yml.
const DefaultEndpoint = "localhost:4318"

// Config describes the exporter target and the identity of this service.
type Config struct {
	ServiceName string
	Version     string
	// Endpoint is an OTLP/HTTP endpoint as host:port, e.g. "localhost:4318".
	// Empty means read OTEL_EXPORTER_OTLP_ENDPOINT, defaulting to
	// localhost:4318.
	Endpoint string
	// Mode is recorded as the demo.mode resource attribute so a trace can be
	// attributed to the broken or the fixed build after the fact.
	Mode string
}

// Endpoint resolves the OTLP endpoint the way Setup does, for logging it.
func Endpoint(configured string) string {
	if configured != "" {
		return configured
	}
	if env := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT"); env != "" {
		return env
	}
	return DefaultEndpoint
}

// Setup installs a global TracerProvider and propagator. The returned shutdown
// function flushes pending spans and must be called before the process exits,
// or the last few seconds of the demo never reach Jaeger.
func Setup(cfg Config) (shutdown func(context.Context) error, err error) {
	ctx := context.Background()
	endpoint := Endpoint(cfg.Endpoint)

	exp, err := otlptracehttp.New(ctx,
		otlptracehttp.WithEndpoint(endpoint),
		otlptracehttp.WithInsecure(),
	)
	if err != nil {
		return nil, fmt.Errorf("otlp exporter: %w", err)
	}

	res, err := resource.Merge(resource.Default(), resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceName(cfg.ServiceName),
		semconv.ServiceVersion(cfg.Version),
		attribute.String("demo.mode", cfg.Mode),
	))
	if err != nil {
		return nil, fmt.Errorf("resource: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.AlwaysSample())),
		sdktrace.WithBatcher(exp,
			// The default batch timeout is 5s. On stage that is five seconds of
			// silence between "run the load" and "the trace appears", during
			// which the natural thing to do is reload Jaeger and find a
			// half-exported trace. One second keeps the loop tight.
			sdktrace.WithBatchTimeout(time.Second),
		),
	)
	otel.SetTracerProvider(tp)

	// W3C tracecontext for the span relationship, baggage for anything the
	// application wants to carry alongside it.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return tp.Shutdown, nil
}

// Flush runs shutdown with a bounded timeout. Every demo-1 binary defers this:
// the batch span processor holds up to a second of spans in memory, and a
// process that exits without flushing loses the very request the speaker just
// demonstrated.
func Flush(shutdown func(context.Context) error, log *slog.Logger) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := shutdown(ctx); err != nil {
		log.Error("telemetry shutdown", "error", err)
	}
}

// Tracer returns the tracer all demo-1 code should use.
func Tracer() trace.Tracer {
	return otel.Tracer("github.com/doniacld/go-observability-demos/demo-01")
}
