// Command portal is the Cloudbox Console — the workshop's hand-rolled
// developer portal (module 08).
//
// The whole point of this program is to demystify portals: it is a plain Go
// web server that (a) reads a handful of Kubernetes resources over the REST
// API with its ServiceAccount token, (b) lists an S3 bucket, and (c) renders
// server-side HTML sprinkled with htmx. No client-go, no React build, no CDN
// — everything it serves is compiled into the binary (offline rule!).
//
// This file is wiring only. The pages live in internal/web — one file per
// page, each registering itself in the page registry (see
// internal/web/registry.go, the console's extension point). Config is
// gathered in config.go; the API clients live in internal/kube,
// internal/store and internal/metrics.
package main

import (
	"log"
	"net/http"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/metrics"
	"cloudbox.io/portal/internal/store"
	"cloudbox.io/portal/internal/web"
)

func main() {
	cfg := loadConfig()

	shutdown := initTelemetry(cfg.OTLPEndpoint, cfg.ServiceName)
	defer shutdown()

	tmpl, err := web.ParseTemplates(cfg.GrafanaURL)
	if err != nil {
		log.Fatalf("parsing templates: %v", err)
	}
	kubeClient, err := kube.NewClient(cfg.KubeAPIURL, cfg.KubeToken)
	if err != nil {
		log.Fatalf("kubernetes client: %v (set KUBE_API_URL when running outside a cluster, e.g. via `kubectl proxy`)", err)
	}
	s3, err := store.New(store.Config{
		Endpoint:       cfg.S3Endpoint,
		PublicEndpoint: cfg.S3PublicEndpoint,
		AccessKey:      cfg.S3AccessKey,
		SecretKey:      cfg.S3SecretKey,
		Bucket:         cfg.S3Bucket,
	})
	if err != nil {
		log.Fatalf("s3 client: %v", err)
	}

	srv := &web.Server{
		Kube:        kubeClient,
		Store:       s3,
		Prom:        metrics.New(cfg.PromURL),
		Tmpl:        tmpl,
		UploaderURL: cfg.UploaderURL,
		GrafanaURL:  cfg.GrafanaURL,
		// otelhttp's transport adds a client span AND a `traceparent` header
		// to the forwarded upload, so the uploader's spans join our trace.
		// 60s timeout: generous, because the first upload wakes the uploader
		// ksvc from zero — but no request may hang forever.
		HTTPClient: &http.Client{Timeout: 60 * time.Second, Transport: otelhttp.NewTransport(nil)},
		Pages:      counter("cloudbox.pages.rendered", "pages and fragments rendered by the console"),
	}

	mux := http.NewServeMux()
	mux.Handle("GET /static/", web.Static())
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	// Every page mounts itself via the registry — adding a page never
	// touches this file (see internal/web/registry.go).
	for _, p := range web.Pages() {
		pattern := "GET " + p.Path
		if p.Path == "/" {
			pattern = "GET /{$}" // exact match, or "/" would swallow every 404
		}
		mux.HandleFunc(pattern, bind(srv, p.Handler))
		for _, extra := range p.Extra {
			mux.HandleFunc(extra.Pattern, bind(srv, extra.Handler))
		}
	}

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

	addr := ":" + cfg.Port
	log.Printf("cloudbox console listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, handler))
}

// bind turns a page handler into a plain http.HandlerFunc with the server's
// dependencies applied.
func bind(s *web.Server, h web.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) { h(s, w, r) }
}
