// Command resizer is the back half of the capstone image pipeline. The
// Knative broker POSTs it a CloudEvent whenever the uploader stores a new
// image; the resizer fetches the original from RustFS, produces a
// 320px-wide JPEG thumbnail and a small JSON analysis, and writes both back
// to the bucket:
//
//	originals/<key>  --->  thumbs/<key>.jpg   (the thumbnail)
//	                 --->  meta/<key>.json    ({width, height, format, bytes, dominantColor})
//
// It runs as a Knative Service scaled to zero — the logs below are written
// for the moment attendees upload an image and watch this pod spring into
// existence to handle it. No CloudEvents SDK here either: receiving a
// binary-mode event means reading a few ce-* headers off a plain POST.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	_ "image/png" // register the PNG decoder for image.Decode
	"io"
	"log"
	"net/http"
	"os"
	"strings"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
	"golang.org/x/image/draw"
)

const thumbWidth = 320

// maxPixels caps the images we are willing to decode. Decoding allocates
// ~4 bytes per pixel, so a 108MP phone photo would want ~430 MB inside a
// 256Mi pod — instant OOMKill. 25MP (a 6000x4000 photo) is plenty for a
// thumbnail pipeline.
const maxPixels = 25_000_000

// permanentError marks failures that no amount of retrying will fix (a
// garbage image stays garbage). handleEvent answers 200 for these so the
// broker does not redeliver them.
type permanentError struct{ error }

func permanent(err error) error  { return permanentError{err} }
func isPermanent(err error) bool { var p permanentError; return errors.As(err, &p) }

type resizer struct {
	s3        *minio.Client
	bucket    string
	processed metric.Int64Counter // OTLP: cloudbox.images.processed → prom cloudbox_images_processed_total
}

func main() {
	shutdown := initTelemetry("cloudbox-resizer")
	defer shutdown()

	endpoint := strings.TrimPrefix(envOr("S3_ENDPOINT", "rustfs-svc.rustfs.svc.cluster.local:9000"), "http://")
	s3, err := minio.New(endpoint, &minio.Options{
		Creds: credentials.NewStaticV4(
			envOr("S3_ACCESS_KEY", "cloudbox"),
			envOr("S3_SECRET_KEY", "cloudbox123"),
			"",
		),
		Secure: false,
	})
	if err != nil {
		log.Fatalf("s3 client: %v", err)
	}
	rz := &resizer{
		s3:        s3,
		bucket:    envOr("S3_BUCKET", "images"),
		processed: counter("cloudbox.images.processed", "images successfully thumbnailed and analyzed"),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /{$}", rz.handleEvent)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	// otelhttp extracts the `traceparent` header the uploader attached to the
	// CloudEvent (and the broker forwarded), so every span below joins the
	// SAME distributed trace as the original upload request.
	handler := otelhttp.NewHandler(mux, "resizer",
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/healthz" }))

	addr := ":" + envOr("PORT", "8080") // Knative injects PORT
	log.Printf("resizer listening on %s — cold start done, ready for events", addr)
	log.Fatal(http.ListenAndServe(addr, handler))
}

// eventData is the payload the uploader puts in its CloudEvents.
type eventData struct {
	Bucket string `json:"bucket"`
	Key    string `json:"key"`
}

// handleEvent receives one CloudEvent from the broker. In binary mode the
// event attributes arrive as HTTP headers (ce-id, ce-type, ce-source, ...)
// and the event data is simply the request body.
func (rz *resizer) handleEvent(w http.ResponseWriter, r *http.Request) {
	id, evType, source := r.Header.Get("ce-id"), r.Header.Get("ce-type"), r.Header.Get("ce-source")
	log.Printf("=== CloudEvent received: id=%s type=%s source=%s", id, evType, source)

	if evType != "dev.cloudbox.image.uploaded" {
		// Shouldn't happen if the Trigger's filter is right — answering 200
		// anyway stops the broker from retrying an event we will never want.
		log.Printf("ignoring unexpected event type %q", evType)
		w.WriteHeader(http.StatusOK)
		return
	}

	var data eventData
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&data); err != nil {
		// Malformed payload is permanent too — redelivering it would just
		// fail identically, so accept-and-drop with a reason.
		dropEvent(w, fmt.Sprintf("bad event data: %v", err))
		return
	}
	if !strings.HasPrefix(data.Key, "originals/") {
		// Guard against event loops: only ever process originals.
		dropEvent(w, fmt.Sprintf("key outside originals/: %q", data.Key))
		return
	}

	// Error semantics matter here: the broker redelivers on non-2xx (capped
	// at ~10 attempts, no dead-letter queue in this setup — each retry is a
	// fresh cold start). So 5xx is reserved for *transient* failures worth
	// retrying (S3/network hiccups); permanent ones — undecodable images,
	// decode bombs, missing keys — are logged and dropped with a 200.
	if err := rz.process(r.Context(), data); err != nil {
		if isPermanent(err) {
			dropEvent(w, err.Error())
			return
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	rz.processed.Add(r.Context(), 1)
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("processed " + data.Key))
}

// dropEvent acknowledges an event we will never be able to process: 200 so
// the broker stops, with the reason in the body and the log.
func dropEvent(w http.ResponseWriter, reason string) {
	log.Printf("DROPPED event (permanent, will not retry): %s", reason)
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("dropped: " + reason))
}

// process is the actual pipeline step: GET original → decode → thumbnail →
// PUT thumbnail + analysis.
func (rz *resizer) process(ctx context.Context, data eventData) error {
	bucket := data.Bucket
	if bucket == "" {
		bucket = rz.bucket
	}

	tracer := otel.Tracer("resizer")

	// Each pipeline step gets a small manual span — in Grafana the trace
	// reads like this function does: download, resize, upload.
	ctx, dl := tracer.Start(ctx, "s3 download original")
	obj, err := rz.s3.GetObject(ctx, bucket, data.Key, minio.GetObjectOptions{})
	if err != nil {
		dl.End()
		return fmt.Errorf("getting %s: %w", data.Key, err)
	}
	defer obj.Close()
	original, err := io.ReadAll(obj)
	dl.End()
	if err != nil {
		// minio's GetObject is lazy — a missing key only surfaces here, at
		// the first read. That one is permanent; anything else (network,
		// RustFS restarting) is worth a retry.
		if minio.ToErrorResponse(err).Code == "NoSuchKey" {
			return permanent(fmt.Errorf("%s does not exist in bucket %s", data.Key, bucket))
		}
		return fmt.Errorf("reading %s: %w", data.Key, err)
	}
	log.Printf("downloaded %s (%d bytes)", data.Key, len(original))

	_, rs := tracer.Start(ctx, "decode and resize")
	src, format, err := decodeChecked(original)
	if err != nil {
		rs.End()
		return permanent(fmt.Errorf("decoding %s: %w", data.Key, err))
	}
	bounds := src.Bounds()
	log.Printf("decoded %s: %dx%d", format, bounds.Dx(), bounds.Dy())

	thumb := thumbnail(src, thumbWidth)
	var jpg bytes.Buffer
	err = jpeg.Encode(&jpg, thumb, &jpeg.Options{Quality: 80})
	rs.End()
	if err != nil {
		return fmt.Errorf("encoding thumbnail: %w", err)
	}

	ctx, up := tracer.Start(ctx, "s3 upload thumbnail and meta")
	defer up.End()
	thumbKey, metaKey := derivedKeys(data.Key)
	if _, err := rz.s3.PutObject(ctx, bucket, thumbKey, &jpg, int64(jpg.Len()),
		minio.PutObjectOptions{ContentType: "image/jpeg"}); err != nil {
		return fmt.Errorf("storing %s: %w", thumbKey, err)
	}
	log.Printf("wrote %s (%dx%d, %d bytes)", thumbKey, thumb.Bounds().Dx(), thumb.Bounds().Dy(), jpg.Len())

	meta, _ := json.Marshal(map[string]any{
		"width":         bounds.Dx(),
		"height":        bounds.Dy(),
		"format":        format,
		"bytes":         len(original),
		"dominantColor": dominantColor(src),
	})
	if _, err := rz.s3.PutObject(ctx, bucket, metaKey, bytes.NewReader(meta), int64(len(meta)),
		minio.PutObjectOptions{ContentType: "application/json"}); err != nil {
		return fmt.Errorf("storing %s: %w", metaKey, err)
	}
	log.Printf("wrote %s: %s", metaKey, meta)
	log.Printf("=== done with %s", data.Key)
	return nil
}

// decodeChecked refuses to decode an image before DecodeConfig has confirmed
// the *declared* dimensions are sane. DecodeConfig reads only the header —
// essential, because a 30-byte PNG can declare 100000x100000 pixels and the
// full decode would then try to allocate ~40 GB. Headers lie; memory doesn't.
func decodeChecked(data []byte) (image.Image, string, error) {
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, "", fmt.Errorf("not a decodable image: %w", err)
	}
	if px := cfg.Width * cfg.Height; px > maxPixels {
		return nil, "", fmt.Errorf("image declares %dx%d = %d pixels, over the %d limit",
			cfg.Width, cfg.Height, px, maxPixels)
	}
	return image.Decode(bytes.NewReader(data))
}

// derivedKeys maps an original's key to where its thumbnail and analysis go.
// originals/x.png → thumbs/x.png.jpg + meta/x.png.json — keeping the base
// key identical is what lets the portal's gallery join them back together.
func derivedKeys(key string) (thumbKey, metaKey string) {
	base := strings.TrimPrefix(key, "originals/")
	return "thumbs/" + base + ".jpg", "meta/" + base + ".json"
}

// thumbnail scales src down to the given width, keeping the aspect ratio.
// CatmullRom is the slowest and prettiest of x/image's scalers — right choice
// for a batch pipeline, wrong choice for a 60fps game.
func thumbnail(src image.Image, width int) image.Image {
	b := src.Bounds()
	if b.Dx() <= width {
		// Never upscale: a 100px original gets a 100px "thumbnail".
		width = b.Dx()
	}
	height := b.Dy() * width / b.Dx()
	if height < 1 {
		height = 1
	}
	dst := image.NewRGBA(image.Rect(0, 0, width, height))
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, b, draw.Over, nil)
	return dst
}

// dominantColor is a deliberately simple analysis: the average color over a
// grid of up to 64x64 sample points, as a #rrggbb hex string. Good enough to
// tell a sunset from a forest — and it is all stdlib.
func dominantColor(img image.Image) string {
	b := img.Bounds()
	stepX, stepY := max(1, b.Dx()/64), max(1, b.Dy()/64)
	var r, g, bl, n uint64
	for y := b.Min.Y; y < b.Max.Y; y += stepY {
		for x := b.Min.X; x < b.Max.X; x += stepX {
			cr, cg, cb, _ := img.At(x, y).RGBA() // 16-bit channels
			r += uint64(cr >> 8)
			g += uint64(cg >> 8)
			bl += uint64(cb >> 8)
			n++
		}
	}
	if n == 0 {
		return "#000000"
	}
	return fmt.Sprintf("#%02x%02x%02x", r/n, g/n, bl/n)
}

func httpError(w http.ResponseWriter, code int, msg string) {
	log.Printf("ERROR: %s", msg)
	http.Error(w, msg, code)
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
