package main

import (
	"log"
	"os"
)

// config gathers every environment variable the console reads — all the
// knobs and all the defaults on one screen. Packages receive plain values;
// nothing outside this file calls os.Getenv.
type config struct {
	Port string // listen port (Knative-style PORT)

	// Kubernetes API. Empty KubeAPIURL means in-cluster (ServiceAccount);
	// for local dev run `kubectl proxy` and point KUBE_API_URL at it.
	KubeAPIURL string
	KubeToken  string

	// Object storage (RustFS). PublicEndpoint is what the BROWSER can reach
	// — presigned URLs embed the host they were signed for.
	S3Endpoint       string
	S3PublicEndpoint string
	S3AccessKey      string
	S3SecretKey      string
	S3Bucket         string

	UploaderURL    string // cluster-internal ksvc the upload form proxies to
	PromURL        string // VictoriaMetrics Prometheus API for the sparklines
	VLogsURL       string // VictoriaLogs query API for the per-component log tail
	GrafanaURL     string // browser-facing Grafana for deep links
	NATSMonitorURL string // NATS monitoring endpoint for the JetStream browser
	ZotURL         string // cluster-internal Zot registry, read by the Builds page
	KagentURL      string // Kagent controller (REST + A2A on :8083), the Case file agent

	OTLPEndpoint string // where traces + metrics are pushed
	ServiceName  string // service.name in traces/metrics
}

func loadConfig() config {
	return config{
		Port:             envOr("PORT", "8080"),
		KubeAPIURL:       os.Getenv("KUBE_API_URL"),
		KubeToken:        os.Getenv("KUBE_TOKEN"),
		S3Endpoint:       envOr("S3_ENDPOINT", "rustfs-svc.rustfs.svc.cluster.local:9000"),
		S3PublicEndpoint: envOr("S3_PUBLIC_ENDPOINT", "localhost:30900"), // RustFS NodePort
		S3AccessKey:      envOr("S3_ACCESS_KEY", "cloudbox"),             // a username, not a secret
		S3SecretKey:      requireSecret("S3_SECRET_KEY", "cloudbox123"),
		S3Bucket:         envOr("S3_BUCKET", "images"),
		UploaderURL:      envOr("UPLOADER_URL", "http://uploader.pipeline.svc.cluster.local"),
		PromURL:          envOr("PROM_URL", "http://victoria-metrics.observability.svc.cluster.local:8428"),
		VLogsURL:         envOr("VLOGS_URL", "http://victoria-logs.observability.svc.cluster.local:9428"),
		GrafanaURL:       envOr("GRAFANA_URL", "http://localhost:30030"),
		NATSMonitorURL:   envOr("NATS_MONITOR_URL", "http://nats.nats.svc.cluster.local:8222"),
		ZotURL:           envOr("ZOT_URL", "http://zot.zot.svc.cluster.local:5000"),
		KagentURL:        envOr("KAGENT_URL", "http://kagent-controller.kagent.svc.cluster.local:8083"),
		OTLPEndpoint:     envOr("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector.observability.svc.cluster.local:4318"),
		ServiceName:      envOr("OTEL_SERVICE_NAME", "cloudbox-portal"),
	}
}

// envOr returns the value of the environment variable key, or def when unset.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// requireSecret returns a secret from the environment, failing CLOSED when it's
// unset: it must be provided (via a Secret in a real deployment), never silently
// fall back to the well-known workshop credential. The lab default is used only
// when LAB_MODE=1 is set explicitly, so a forgotten secret is a loud startup
// failure rather than a quiet run on a public password (adversarial review S3).
func requireSecret(key, labDefault string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	if os.Getenv("LAB_MODE") == "1" {
		return labDefault
	}
	log.Fatalf("%s is required — set it (a Secret in production), or set LAB_MODE=1 to use the workshop default", key)
	return ""
}
