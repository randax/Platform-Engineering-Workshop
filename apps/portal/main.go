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
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/metric"
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
	prom        *promClient
	tmpl        *template.Template
	uploaderURL string              // cluster-internal URL of the uploader Knative Service
	httpClient  *http.Client        // traced client for forwarding uploads
	pages       metric.Int64Counter // OTLP: cloudbox.pages.rendered → prom cloudbox_pages_rendered_total
}

// parseTemplates registers the one template function the layout needs
// (the Grafana link in the sidebar footer) and parses everything embedded.
func parseTemplates() (*template.Template, error) {
	return template.New("portal").
		Funcs(template.FuncMap{"grafanaURL": grafanaBase}).
		ParseFS(templateFS, "templates/*.html")
}

func main() {
	shutdown := initTelemetry("cloudbox-portal")
	defer shutdown()

	tmpl, err := parseTemplates()
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
		prom:        newPromClient(),
		tmpl:        tmpl,
		pages:       counter("cloudbox.pages.rendered", "pages and fragments rendered by the console"),
		uploaderURL: envOr("UPLOADER_URL", "http://uploader.pipeline.svc.cluster.local"),
		// otelhttp's transport adds a client span AND a `traceparent` header
		// to the forwarded upload, so the uploader's spans join our trace.
		// 60s timeout: generous, because the first upload wakes the uploader
		// ksvc from zero — but no request may hang forever.
		httpClient: &http.Client{Timeout: 60 * time.Second, Transport: otelhttp.NewTransport(nil)},
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
	mux.HandleFunc("GET /activity", srv.handleActivity)
	mux.HandleFunc("GET /activity/list", srv.handleActivityList) // polled by htmx
	mux.HandleFunc("GET /billing", srv.handleBilling)
	mux.HandleFunc("GET /databases", srv.handleDatabases)
	mux.HandleFunc("GET /databases/list", srv.handleDatabasesList) // polled by htmx
	mux.HandleFunc("GET /databases/{name}", srv.handleDatabaseDetail)
	// Mutating routes. No CSRF token on these: single-user disposable lab —
	// don't copy this into a real portal.
	mux.HandleFunc("POST /databases", srv.handleCreateDatabase)
	mux.HandleFunc("DELETE /databases/{name}", srv.handleDeleteDatabase)
	mux.HandleFunc("POST /gallery/upload", srv.handleUpload)
	mux.HandleFunc("GET /gallery", srv.handleGallery)
	mux.HandleFunc("GET /gallery/grid", srv.handleGalleryGrid)
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
