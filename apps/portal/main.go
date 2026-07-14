// Command portal is the Cloudbox Console — the workshop's hand-rolled
// developer portal (module 08).
//
// The whole point of this program is to demystify portals: it is a plain Go
// web server that (a) reads a handful of Kubernetes resources over the REST
// API with its ServiceAccount token, (b) lists an S3 bucket, and (c) renders
// server-side HTML sprinkled with htmx. No client-go, no React build, no CDN
// — everything it serves is compiled into the binary (offline rule!).
//
// Pages:
//
//	/           Overview  — ArgoCD Applications, health + sync status
//	/databases  Databases — CNPG Clusters + WorkshopDatabase XRs (create/delete)
//	/gallery    Gallery   — the capstone image pipeline's bucket
//	/services   Services  — Knative Services with URLs
package main

import (
	"embed"
	"html/template"
	"log"
	"net/http"
	"os"
	"strings"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

//go:embed templates/*.html
var templateFS embed.FS

// static/ holds htmx.min.js (vendored, v2.0.4) and the stylesheet. Embedding
// them means the portal has zero runtime dependencies on the internet.
//
//go:embed static
var staticFS embed.FS

type server struct {
	kube        *kubeClient
	s3          *s3Client
	tmpl        *template.Template
	uploaderURL string       // cluster-internal URL of the uploader Knative Service
	httpClient  *http.Client // traced client for forwarding uploads
}

func main() {
	shutdown := initTracing("cloudbox-portal")
	defer shutdown()

	tmpl, err := template.ParseFS(templateFS, "templates/*.html")
	if err != nil {
		log.Fatalf("parsing templates: %v", err)
	}

	kube, err := newKubeClient()
	if err != nil {
		log.Fatalf("kubernetes client: %v (set KUBE_API_URL when running outside a cluster, e.g. via `kubectl proxy`)", err)
	}

	s3, err := newS3Client()
	if err != nil {
		log.Fatalf("s3 client: %v", err)
	}

	srv := &server{
		kube:        kube,
		s3:          s3,
		tmpl:        tmpl,
		uploaderURL: envOr("UPLOADER_URL", "http://uploader.pipeline.svc.cluster.local"),
		// otelhttp's transport adds a client span AND a `traceparent` header
		// to the forwarded upload, so the uploader's spans join our trace.
		httpClient: &http.Client{Transport: otelhttp.NewTransport(nil)},
	}

	mux := http.NewServeMux()
	mux.Handle("GET /static/", http.FileServerFS(staticFS))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	mux.HandleFunc("GET /{$}", srv.handleOverview)
	mux.HandleFunc("GET /components", srv.handleComponents)
	mux.HandleFunc("GET /components/list", srv.handleComponentsList) // polled by htmx
	mux.HandleFunc("GET /workshop", srv.handleWorkshop)
	mux.HandleFunc("GET /workshop/list", srv.handleWorkshopList) // polled by htmx
	mux.HandleFunc("GET /databases", srv.handleDatabases)
	mux.HandleFunc("GET /databases/list", srv.handleDatabasesList) // polled by htmx
	mux.HandleFunc("POST /databases", srv.handleCreateDatabase)
	mux.HandleFunc("DELETE /databases/{name}", srv.handleDeleteDatabase)
	mux.HandleFunc("GET /gallery", srv.handleGallery)
	mux.HandleFunc("GET /gallery/grid", srv.handleGalleryGrid)
	mux.HandleFunc("POST /gallery/upload", srv.handleUpload)
	mux.HandleFunc("GET /services", srv.handleServices)

	// One server span per page request; health probes and static assets
	// would only be noise in Grafana.
	handler := otelhttp.NewHandler(mux, "portal",
		otelhttp.WithFilter(func(r *http.Request) bool {
			return r.URL.Path != "/healthz" && !strings.HasPrefix(r.URL.Path, "/static/")
		}),
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
			return r.Method + " " + r.URL.Path
		}),
	)

	addr := ":" + envOr("PORT", "8080")
	log.Printf("cloudbox console listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, handler))
}

// envOr returns the value of the environment variable key, or def when unset.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
