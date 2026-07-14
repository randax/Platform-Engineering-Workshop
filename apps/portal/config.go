package main

import "os"

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

	UploaderURL string // cluster-internal ksvc the upload form proxies to
	PromURL     string // Prometheus API for the sparklines
	GrafanaURL  string // browser-facing Grafana for deep links

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
		S3AccessKey:      envOr("S3_ACCESS_KEY", "cloudbox"),
		S3SecretKey:      envOr("S3_SECRET_KEY", "cloudbox123"),
		S3Bucket:         envOr("S3_BUCKET", "images"),
		UploaderURL:      envOr("UPLOADER_URL", "http://uploader.pipeline.svc.cluster.local"),
		PromURL:          envOr("PROM_URL", "http://lgtm.observability.svc.cluster.local:9090"),
		GrafanaURL:       envOr("GRAFANA_URL", "http://localhost:30030"),
		OTLPEndpoint:     envOr("OTEL_EXPORTER_OTLP_ENDPOINT", "http://lgtm.observability.svc.cluster.local:4318"),
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
