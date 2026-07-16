package web

// The Services page: Knative Services with request-rate sparklines and
// Grafana trace links.

import (
	"fmt"
	"html/template"
	"net/http"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/metrics"
)

func init() {
	register(Page{
		Weight:     70,
		NavSection: "Self-service",
		NavTitle:   "Services",
		Path:       "/services",
		Handler:    handleServices,
		// Serverless (module 06): nothing to list until Knative Serving is
		// installed and Healthy — the ksvc CRD doesn't even exist before then.
		Unlock:     func(s kube.Snapshot) bool { _, h := s.AppHealthy("knative-serving"); return h },
		LockedHint: "Complete Module 06 · Serverless",
		Teaser:     "Deploy serverless workloads that scale to zero and back — request-rate sparklines and one-click Grafana trace links included.",
	})
}

// serviceRow decorates a Knative Service with its request-rate sparkline
// and a Grafana trace-search link. Instrumented services report to
// Prometheus under job = OTEL_SERVICE_NAME = "cloudbox-<name>"; anything
// uninstrumented simply has no series and renders the empty-state dash.
type serviceRow struct {
	kube.KnativeService
	Spark      template.HTML // request rate, last 30 min
	Latency    template.HTML // p95 request latency, last 30 min
	LatencyNow string        // the latest p95, in ms
	Grafana    string
}

func handleServices(s *Server, w http.ResponseWriter, r *http.Request) {
	svcs, err := s.Kube.ListKnativeServices(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	rows := make([]serviceRow, 0, len(svcs))
	for _, k := range svcs {
		job := "cloudbox-" + k.Metadata.Name
		row := serviceRow{KnativeService: k, Grafana: grafanaTraces(s.GrafanaURL, job)}
		// Sparkline is best-effort: a prom error means the same thing as no
		// data — the dash renders, the page never fails over decoration.
		if vals, err := s.Prom.QueryRange(r.Context(), metrics.RequestRateQuery(job)); err == nil {
			row.Spark = metrics.Sparkline(vals, "request rate")
		}
		// Mean latency from the same histogram (best-effort, same as the rate).
		if vals, err := s.Prom.QueryRange(r.Context(), metrics.LatencyAvgQuery(job)); err == nil && len(vals) > 0 {
			row.Latency = metrics.Sparkline(vals, "avg latency")
			row.LatencyNow = fmt.Sprintf("%.0f ms", vals[len(vals)-1]*1000)
		}
		rows = append(rows, row)
	}
	s.render(w, "services", rows)
}
