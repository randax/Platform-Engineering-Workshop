package nats

// Hermetic tests for the JetStream /jsz decoding — a raw net/http + New(url)
// client structurally identical to the metrics/logs clients, but previously 0%
// covered, so a NATS monitoring API-shape change was caught only by the weekly
// rehearsal (adversarial review F5).

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestListStreams(t *testing.T) {
	body := `{"account_details":[{"stream_detail":[
		{"config":{"name":"ORDERS"},"state":{"messages":42,"bytes":2048,"consumer_count":3}},
		{"config":{"name":"EVENTS"},"state":{"messages":0,"bytes":0,"consumer_count":0}}
	]}]}`
	var gotPath, gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotQuery = r.URL.Path, r.URL.RawQuery
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	streams, err := New(srv.URL).ListStreams(context.Background())
	if err != nil {
		t.Fatalf("ListStreams: %v", err)
	}
	if gotPath != "/jsz" {
		t.Errorf("path = %q, want /jsz", gotPath)
	}
	if !strings.Contains(gotQuery, "streams=1") || !strings.Contains(gotQuery, "consumers=1") {
		t.Errorf("query = %q, want the streams+consumers flags (else /jsz returns only totals)", gotQuery)
	}
	if len(streams) != 2 {
		t.Fatalf("got %d streams, want 2 (flattened across accounts)", len(streams))
	}
	// Order-agnostic (the listing may sort): find ORDERS and check its fields.
	byName := map[string]Stream{}
	for _, s := range streams {
		byName[s.Name] = s
	}
	if want := (Stream{Name: "ORDERS", Messages: 42, Bytes: 2048, Consumers: 3}); byName["ORDERS"] != want {
		t.Errorf("ORDERS stream = %+v, want %+v", byName["ORDERS"], want)
	}
	if _, ok := byName["EVENTS"]; !ok {
		t.Errorf("EVENTS stream missing from %+v", streams)
	}
}

func TestListStreamsEmpty(t *testing.T) {
	// A JetStream-less NATS answers 200 with no account/stream detail — that's a
	// normal state (nil, no error), not a failure.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"account_details":[]}`))
	}))
	defer srv.Close()
	streams, err := New(srv.URL).ListStreams(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(streams) != 0 {
		t.Errorf("got %d streams, want 0", len(streams))
	}
}

func TestListStreamsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	if _, err := New(srv.URL).ListStreams(context.Background()); err == nil {
		t.Error("expected an error on HTTP 500")
	}
}
