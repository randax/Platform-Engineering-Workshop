package main

import "testing"

// Telemetry setup must never block startup or fail the app when no
// collector is reachable — observability being down is a normal state.
func TestInitTelemetryWithoutCollector(t *testing.T) {
	shutdown := initTelemetry("http://127.0.0.1:1", "test-service")
	c := counter("cloudbox.test.events", "test counter")
	c.Add(t.Context(), 1) // must be usable immediately, collector or not
	shutdown()            // flushes into the void; must return promptly
}
