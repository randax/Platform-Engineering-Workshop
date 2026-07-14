package main

import "testing"

// The tracing setup must never block startup or fail the app when no
// collector is reachable — the same lesson as the uploader's ensureBucket:
// observability being down is a normal state, not a crash.
func TestInitTracingWithoutCollector(t *testing.T) {
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:1")
	shutdown := initTracing("test-service")
	shutdown() // flushes into the void; must return promptly, not hang
}
