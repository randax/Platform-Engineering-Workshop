package main

import (
	"bytes"
	"context"
	"image"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
)

// The CloudEvent POST must carry BOTH the ce-* attributes and a W3C
// `traceparent` header — the latter is what keeps the resizer's spans in the
// same distributed trace once the broker forwards the event.
func TestEmitEventCarriesTraceparent(t *testing.T) {
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:1") // no collector needed
	shutdown := initTelemetry("test-uploader")
	defer shutdown()

	var traceparent, ceType, ceSource string
	broker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		traceparent = r.Header.Get("traceparent")
		ceType = r.Header.Get("ce-type")
		ceSource = r.Header.Get("ce-source")
		w.WriteHeader(http.StatusAccepted)
	}))
	defer broker.Close()

	u := &uploader{
		bucket:    "images",
		brokerURL: broker.URL,
		http:      &http.Client{Timeout: 5 * time.Second, Transport: otelhttp.NewTransport(nil)},
		uploads:   counter("cloudbox.uploads.accepted", "test"),
	}

	// Simulate being inside a request span, like handleUpload is.
	ctx, span := otel.Tracer("test").Start(context.Background(), "upload")
	err := u.emitEvent(ctx, "originals/1-x.png")
	span.End()
	if err != nil {
		t.Fatalf("emitEvent: %v", err)
	}
	if ceType != "dev.cloudbox.image.uploaded" || ceSource != "cloudbox/uploader" {
		t.Errorf("ce headers wrong: type=%q source=%q", ceType, ceSource)
	}
	if traceparent == "" {
		t.Error("no traceparent header on the CloudEvent POST — the resizer would start a disconnected trace")
	}
}

func encode(t *testing.T, format string) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	var buf bytes.Buffer
	var err error
	switch format {
	case "png":
		err = png.Encode(&buf, img)
	case "jpeg":
		err = jpeg.Encode(&buf, img, nil)
	}
	if err != nil {
		t.Fatalf("encoding %s: %v", format, err)
	}
	return buf.Bytes()
}

func TestDetectImage(t *testing.T) {
	if ct, err := detectImage(encode(t, "png")); err != nil || ct != "image/png" {
		t.Errorf("png: got (%q, %v)", ct, err)
	}
	if ct, err := detectImage(encode(t, "jpeg")); err != nil || ct != "image/jpeg" {
		t.Errorf("jpeg: got (%q, %v)", ct, err)
	}
	// Things that must be rejected: scripts, GIFs, empty uploads.
	for _, bad := range [][]byte{
		[]byte("#!/bin/sh\nrm -rf /\n"),
		[]byte("GIF89a...."),
		{},
	} {
		if ct, err := detectImage(bad); err == nil {
			t.Errorf("expected rejection, got %q for %q", ct, bad)
		}
	}
}

func TestSanitizeName(t *testing.T) {
	cases := map[string]string{
		"cat.jpg":               "cat.jpg",
		"../../etc/passwd":      "passwd",
		"C:\\Users\\x\\dog.png": "dog.png",
		"my photo (1).png":      "my-photo-1-.png",
		"":                      "upload",
		"héllo wörld.jpeg":      "h-llo-w-rld.jpeg",
	}
	for in, want := range cases {
		if got := sanitizeName(in); got != want {
			t.Errorf("sanitizeName(%q) = %q, want %q", in, got, want)
		}
	}
}
