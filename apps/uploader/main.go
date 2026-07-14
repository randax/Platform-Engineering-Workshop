// Command uploader is the front half of the capstone image pipeline: it
// accepts an image over HTTP, stores it in the `images` bucket on RustFS,
// and announces the fact as a CloudEvent to the Knative broker.
//
// It runs as a Knative Service in the `pipeline` namespace and scales to
// zero when idle. Note what is deliberately NOT here: no CloudEvents SDK.
// A binary-mode CloudEvent is an ordinary HTTP POST with five ce-* headers —
// see emitEvent below.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
)

type uploader struct {
	s3        *minio.Client
	bucket    string
	brokerURL string
	http      *http.Client
}

func main() {
	shutdown := initTracing("cloudbox-uploader")
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

	u := &uploader{
		s3:        s3,
		bucket:    envOr("S3_BUCKET", "images"),
		brokerURL: envOr("BROKER_URL", "http://broker-ingress.knative-eventing.svc.cluster.local/pipeline/default"),
		// otelhttp's transport adds a `traceparent` header to the CloudEvent
		// POST. Knative's broker forwards it along with the ce-* headers, so
		// the resizer's spans land in the SAME trace as this upload.
		http: &http.Client{Timeout: 10 * time.Second, Transport: otelhttp.NewTransport(nil)},
	}
	// In the background so a slow or still-converging RustFS can never block
	// the listener — Knative needs the port open to consider the pod ready.
	go u.ensureBucket()

	mux := http.NewServeMux()
	mux.HandleFunc("POST /upload", u.handleUpload)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	// One server span per upload; the portal's `traceparent` header makes it
	// a child of the portal's span. Health probes stay untraced.
	handler := otelhttp.NewHandler(mux, "uploader",
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/healthz" }))

	addr := ":" + envOr("PORT", "8080") // Knative injects PORT
	log.Printf("uploader listening on %s (bucket %q, broker %s)", addr, u.bucket, u.brokerURL)
	log.Fatal(http.ListenAndServe(addr, handler))
}

// ensureBucket creates the bucket if it does not exist yet. Failure is only
// logged: the pod must still come up so /healthz can answer while RustFS is
// converging.
func (u *uploader) ensureBucket() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ok, err := u.s3.BucketExists(ctx, u.bucket)
	if err != nil {
		log.Printf("WARN: cannot reach S3 yet: %v", err)
		return
	}
	if !ok {
		if err := u.s3.MakeBucket(ctx, u.bucket, minio.MakeBucketOptions{}); err != nil {
			log.Printf("WARN: creating bucket %q: %v", u.bucket, err)
			return
		}
		log.Printf("created bucket %q", u.bucket)
	}
}

// maxUploadBytes caps uploads at 25 MB. Besides basic hygiene, this keeps
// the request under Go's 32 MB multipart threshold — above it, form parsing
// spills to a temp file, and a FROM scratch image has no /tmp to spill to.
const maxUploadBytes = 25 << 20

// handleUpload: multipart POST with a "file" field → originals/<ts>-<name>
// in S3 → CloudEvent to the broker → JSON reply.
func (u *uploader) handleUpload(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBytes)
	file, hdr, err := r.FormFile("file")
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			jsonError(w, http.StatusRequestEntityTooLarge, "upload too large (max 25 MB)")
			return
		}
		jsonError(w, http.StatusBadRequest, fmt.Sprintf("expected multipart field %q: %v", "file", err))
		return
	}
	defer file.Close()

	// Sniff the real content type from the first 512 bytes — the browser's
	// claimed Content-Type is not trustworthy.
	head := make([]byte, 512)
	n, _ := io.ReadFull(file, head)
	contentType, err := detectImage(head[:n])
	if err != nil {
		jsonError(w, http.StatusUnsupportedMediaType, err.Error())
		return
	}

	key := fmt.Sprintf("originals/%d-%s", time.Now().Unix(), sanitizeName(hdr.Filename))

	// We already consumed the head while sniffing, so stitch it back on.
	// The manual span shows the S3 write as its own step in the trace.
	ctx, span := otel.Tracer("uploader").Start(r.Context(), "s3 put original")
	body := io.MultiReader(bytes.NewReader(head[:n]), file)
	info, err := u.s3.PutObject(ctx, u.bucket, key, body, hdr.Size,
		minio.PutObjectOptions{ContentType: contentType})
	span.End()
	if err != nil {
		jsonError(w, http.StatusBadGateway, fmt.Sprintf("storing object: %v", err))
		return
	}
	log.Printf("stored %s (%d bytes, %s)", key, info.Size, contentType)

	eventErr := u.emitEvent(r.Context(), key)
	if eventErr != nil {
		// The object is safely stored; only the event failed. Say so instead
		// of failing the upload — before the eventing module is enabled this
		// is the expected state.
		log.Printf("WARN: emitting CloudEvent: %v", eventErr)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"bucket":      u.bucket,
		"key":         key,
		"bytes":       info.Size,
		"contentType": contentType,
		"eventSent":   eventErr == nil,
		"eventError":  errString(eventErr),
	})
}

// emitEvent sends a binary-mode CloudEvent to the broker ingress. This is
// the whole spec in practice: an HTTP POST where the event attributes travel
// as ce-* headers and the payload is the body. The broker answers
// 202 Accepted once it has taken responsibility for delivering the event to
// every matching Trigger.
func (u *uploader) emitEvent(ctx context.Context, key string) error {
	payload, _ := json.Marshal(map[string]string{"bucket": u.bucket, "key": key})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.brokerURL, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("ce-specversion", "1.0")
	req.Header.Set("ce-id", newID())
	req.Header.Set("ce-source", "cloudbox/uploader")
	req.Header.Set("ce-type", "dev.cloudbox.image.uploaded")

	resp, err := u.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("broker replied %s: %s", resp.Status, msg)
	}
	log.Printf("emitted dev.cloudbox.image.uploaded for %s (broker said %s)", key, resp.Status)
	return nil
}

// detectImage validates the sniffed content type; only JPEG and PNG pass.
func detectImage(head []byte) (string, error) {
	ct := http.DetectContentType(head)
	switch ct {
	case "image/jpeg", "image/png":
		return ct, nil
	default:
		return "", fmt.Errorf("only JPEG and PNG are accepted, this looks like %s", ct)
	}
}

var unsafeChars = regexp.MustCompile(`[^a-zA-Z0-9._-]+`)

// sanitizeName reduces an arbitrary browser-supplied filename to something
// safe to use inside an object key.
func sanitizeName(name string) string {
	name = path.Base(strings.ReplaceAll(name, "\\", "/"))
	name = unsafeChars.ReplaceAllString(name, "-")
	if name == "" || name == "." {
		name = "upload"
	}
	return name
}

func newID() string {
	b := make([]byte, 8)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func jsonError(w http.ResponseWriter, code int, msg string) {
	log.Printf("rejected upload: %s", msg)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
