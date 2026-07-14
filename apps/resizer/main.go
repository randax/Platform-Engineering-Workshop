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
	"golang.org/x/image/draw"
)

const thumbWidth = 320

type resizer struct {
	s3     *minio.Client
	bucket string
}

func main() {
	shutdown := initTracing("cloudbox-resizer")
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
	rz := &resizer{s3: s3, bucket: envOr("S3_BUCKET", "images")}

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
		httpError(w, http.StatusBadRequest, fmt.Sprintf("bad event data: %v", err))
		return
	}
	if !strings.HasPrefix(data.Key, "originals/") {
		// Guard against event loops: only ever process originals.
		log.Printf("ignoring key outside originals/: %q", data.Key)
		w.WriteHeader(http.StatusOK)
		return
	}

	// A non-2xx response makes the broker redeliver the event later, so
	// transient failures (RustFS restarting, ...) heal themselves.
	if err := rz.process(r.Context(), data); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("processed " + data.Key))
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
		return fmt.Errorf("reading %s: %w", data.Key, err)
	}
	log.Printf("downloaded %s (%d bytes)", data.Key, len(original))

	_, rs := tracer.Start(ctx, "decode and resize")
	src, format, err := image.Decode(bytes.NewReader(original))
	if err != nil {
		rs.End()
		return fmt.Errorf("decoding %s: %w", data.Key, err)
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
