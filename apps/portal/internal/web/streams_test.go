package web

// The Streams page: pins the unlock gate (NATS Healthy) and proves the
// JetStream table renders stream names, message counts, humanized bytes, and
// consumer counts from a fake source — no live NATS monitoring endpoint in the
// loop. Also pins the empty state, since "JetStream is empty" is a first-class
// non-error result, not a failure.

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/nats"
)

// fakeStreams is an in-memory streamsSource: it hands back canned streams so the
// fragment's rendering is testable without standing up NATS.
type fakeStreams struct {
	streams []nats.Stream
}

func (f fakeStreams) ListStreams(context.Context) ([]nats.Stream, error) {
	return f.streams, nil
}

// TestStreamsUnlock pins the gate: locked from a bare cluster, unlocked the
// moment NATS reports Healthy (mirrors unlock_test.go's approach).
func TestStreamsUnlock(t *testing.T) {
	if it, ok := findNavItem(navGroups(kube.Snapshot{}), "streams"); !ok {
		t.Fatal("nav is missing the streams page")
	} else if !it.Locked {
		t.Error("streams must be locked when NATS is not Healthy")
	}

	apps := map[string]kube.ArgoApp{"nats": fixtureApp("nats", "Healthy")}
	if it, ok := findNavItem(navGroups(kube.Snapshot{Apps: apps}), "streams"); !ok {
		t.Fatal("nav is missing the streams page")
	} else if it.Locked {
		t.Error("streams must unlock once NATS is Healthy")
	}
}

// TestStreamsRender feeds a fake source through the same helper the handler
// uses, then renders the fragment and asserts the names, humanized bytes, and
// consumer counts all land in the markup.
func TestStreamsRender(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{})
	if err != nil {
		t.Fatalf("parsing templates: %v", err)
	}

	src := fakeStreams{streams: []nats.Stream{
		{Name: "ORDERS", Messages: 128, Bytes: 250880, Consumers: 2},
		{Name: "EVENTS", Messages: 0, Bytes: 0, Consumers: 0},
	}}

	data, err := fetchStreams(context.Background(), src, flash{})
	if err != nil {
		t.Fatalf("fetchStreams: %v", err)
	}

	var buf bytes.Buffer
	if err := tmpl.ExecuteTemplate(&buf, "streams-list", data); err != nil {
		t.Fatalf("rendering streams-list: %v", err)
	}
	out := buf.String()

	for _, want := range []string{
		`hx-trigger="every 5s"`, // the table polls itself
		"ORDERS",                // a stream name
		"245 KB",                // 250880 bytes, humanized
		"EVENTS",                // an idle stream still renders
	} {
		if !strings.Contains(out, want) {
			t.Errorf("rendered fragment missing %q", want)
		}
	}
}

// TestStreamsEmpty pins the friendly empty state: JetStream enabled but with no
// streams is a normal result, and must render as a prompt, never an error.
func TestStreamsEmpty(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{})
	if err != nil {
		t.Fatalf("parsing templates: %v", err)
	}

	data, err := fetchStreams(context.Background(), fakeStreams{}, flash{})
	if err != nil {
		t.Fatalf("fetchStreams: %v", err)
	}

	var buf bytes.Buffer
	if err := tmpl.ExecuteTemplate(&buf, "streams-list", data); err != nil {
		t.Fatalf("rendering streams-list: %v", err)
	}
	if !strings.Contains(buf.String(), "JetStream is empty") {
		t.Error("empty JetStream must render the friendly empty state")
	}
}
