package main

// Telemetry setup: traces AND metrics, both pushed over OTLP/HTTP to the
// platform's grafana/otel-lgtm pod. W3C `traceparent` propagation on every
// HTTP hop is what stitches the capstone chain — portal → uploader → broker
// → resizer — into ONE distributed trace in Grafana; the metrics feed the
// sparklines the portal renders itself.
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
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// initTelemetry configures the global tracer AND meter providers. It never
// blocks and never fails the app: if the collector is unreachable, the
// background exporters keep dropping data while everything else works — the
// observability stack being off is a normal state in this workshop.
func initTelemetry(serviceName string) (shutdown func()) {
	endpoint := envOr("OTEL_EXPORTER_OTLP_ENDPOINT", "http://lgtm.observability.svc.cluster.local:4318")
	if v := os.Getenv("OTEL_SERVICE_NAME"); v != "" {
		serviceName = v
	}
	res := resource.NewWithAttributes(semconv.SchemaURL, semconv.ServiceName(serviceName))
	ctx := context.Background()
	var shutdowns []func(context.Context) error

	// --- traces ---
	if texp, err := otlptracehttp.New(ctx, otlptracehttp.WithEndpointURL(endpoint)); err != nil {
		log.Printf("WARN: tracing disabled: %v", err)
	} else {
		tp := sdktrace.NewTracerProvider(
			sdktrace.WithBatcher(texp), // batches + exports asynchronously
			sdktrace.WithResource(res),
		)
		otel.SetTracerProvider(tp)
		shutdowns = append(shutdowns, tp.Shutdown)
	}

	// --- metrics ---
	// Same endpoint, pushed every 15s by a background reader. Setting the
	// GLOBAL meter provider is what makes otelhttp emit request count and
	// duration histograms for free — no extra code in the handlers.
	if mexp, err := otlpmetrichttp.New(ctx, otlpmetrichttp.WithEndpointURL(endpoint)); err != nil {
		log.Printf("WARN: metrics disabled: %v", err)
	} else {
		mp := sdkmetric.NewMeterProvider(
			sdkmetric.WithReader(sdkmetric.NewPeriodicReader(mexp, sdkmetric.WithInterval(15*time.Second))),
			sdkmetric.WithResource(res),
		)
		otel.SetMeterProvider(mp)
		shutdowns = append(shutdowns, mp.Shutdown)
	}

	// This registers the propagator that writes/reads `traceparent` headers —
	// without it every service would start its own disconnected trace.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{}))

	// Export failures repeat every interval; one log line is enough.
	var once sync.Once
	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) {
		once.Do(func() { log.Printf("WARN: telemetry export failing (is otel-lgtm running?): %v", err) })
	}))

	log.Printf("telemetry: OTLP traces+metrics to %s as service %q", endpoint, serviceName)
	return func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		for _, fn := range shutdowns {
			fn(ctx)
		}
	}
}

// counter returns a monotonic counter from the global meter. OTel instrument
// names use dots; Prometheus normalizes them on ingest — e.g.
// "cloudbox.pages.rendered" becomes `cloudbox_pages_rendered_total`.
func counter(name, desc string) metric.Int64Counter {
	c, err := otel.Meter("cloudbox").Int64Counter(name, metric.WithDescription(desc))
	if err != nil {
		log.Printf("WARN: creating counter %s: %v", name, err)
	}
	return c
}
