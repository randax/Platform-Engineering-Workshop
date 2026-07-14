package main

// Tracing setup, in about 40 lines. Spans are pushed over OTLP/HTTP to the
// platform's grafana/otel-lgtm pod, and W3C `traceparent` headers are
// propagated on every HTTP hop. That propagation is the whole trick behind
// the capstone's teaching win: portal → uploader → broker → resizer shows up
// in Grafana as ONE distributed trace.
//
// The portal and resizer carry an identical copy of this file — the only
// difference is the service name passed in from main.

import (
	"context"
	"log"
	"os"
	"sync"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// initTracing configures the global tracer provider. It never blocks and
// never fails the app: if the collector is unreachable, the batch exporter
// keeps dropping spans in the background while everything else works — the
// observability stack being off is a normal state in this workshop.
func initTracing(serviceName string) (shutdown func()) {
	endpoint := envOr("OTEL_EXPORTER_OTLP_ENDPOINT", "http://lgtm.observability.svc.cluster.local:4318")
	if v := os.Getenv("OTEL_SERVICE_NAME"); v != "" {
		serviceName = v
	}

	exporter, err := otlptracehttp.New(context.Background(), otlptracehttp.WithEndpointURL(endpoint))
	if err != nil {
		log.Printf("WARN: tracing disabled: %v", err)
		return func() {}
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter), // batches + exports asynchronously
		sdktrace.WithResource(resource.NewWithAttributes(semconv.SchemaURL,
			semconv.ServiceName(serviceName))),
	)
	otel.SetTracerProvider(tp)

	// This registers the propagator that writes/reads `traceparent` headers —
	// without it every service would start its own disconnected trace.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{}))

	// Export failures repeat every batch interval; one log line is enough.
	var once sync.Once
	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) {
		once.Do(func() { log.Printf("WARN: trace export failing (is otel-lgtm running?): %v", err) })
	}))

	log.Printf("tracing: OTLP to %s as service %q", endpoint, serviceName)
	return func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		tp.Shutdown(ctx)
	}
}
