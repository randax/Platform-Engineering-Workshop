package web

// The Function (Knative Service) detail page — parity with the Application and
// Database detail views. A function's depth (its URL + conditions, the "why"
// when a revision fails, scale-from-zero state, request/latency metrics, a
// traces deep-link, and Invoke/Delete) lives here; the Functions list stays a
// scannable triage table with just the request-rate sparkline.

import (
	"fmt"
	"html/template"
	"net/http"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/metrics"
)

type fnDetailData struct {
	Name      string
	Namespace string
	Found     bool
	Readiness kube.Readiness
	URL       string
	Deletable bool // in a project namespace → the portal may delete it

	// Diagnostics — the "why" when a revision isn't Ready (DR-0005).
	Why      string
	Diag     kube.Diagnostics
	ShowDiag bool

	// Monitoring — request rate + latency + scale-from-zero, best-effort.
	Telemetry bool
	ReqSpark  template.HTML
	LatSpark  template.HTML
	LatNow    string
	Scale     string
	TracesURL string
}

func handleFunctionDetail(s *Server, w http.ResponseWriter, r *http.Request) {
	ns, name := r.PathValue("namespace"), r.PathValue("name")
	if !kube.ValidName(ns) || !kube.ValidName(name) {
		http.NotFound(w, r)
		return
	}
	svc, err := s.Kube.GetKnativeService(r.Context(), ns, name)
	if err != nil {
		s.renderError(w, err)
		return
	}
	data := fnDetailData{Name: name, Namespace: ns}
	if svc == nil {
		s.render(w, "function-detail", data) // Found == false
		return
	}
	data.Found = true
	data.Readiness = svc.Readiness()
	data.URL = svc.Status.URL

	// Delete is offered only for functions in a project namespace (the portal's
	// portal-tenant grant) — same rule as the list.
	for _, p := range s.projectList(r.Context()) {
		if p == ns {
			data.Deletable = true
			break
		}
	}

	if data.Readiness.Class != "ok" {
		data.Why = svc.Why()
		if diag, derr := s.Kube.NamespaceDiagnostics(r.Context(), ns); derr == nil {
			data.Diag = diag
			data.ShowDiag = data.Why != "" || !diag.Empty()
		}
	}

	job := "cloudbox-" + name
	data.TracesURL = grafanaTraces(s.GrafanaURL, job)
	if health, herr := s.Kube.NamespaceWorkloads(r.Context()); herr == nil && health["observability"].Ready > 0 && s.Prom != nil {
		data.Telemetry = true
		if v, _ := s.Prom.QueryRange(r.Context(), metrics.RequestRateQuery(job)); len(v) > 0 {
			data.ReqSpark = metrics.Sparkline(v, "request rate")
		}
		if v, _ := s.Prom.QueryRange(r.Context(), metrics.LatencyAvgQuery(job)); len(v) > 0 {
			data.LatSpark = metrics.Sparkline(v, "avg latency")
			data.LatNow = fmt.Sprintf("%.0f ms", v[len(v)-1]*1000)
		}
		if v, _ := s.Prom.QueryRange(r.Context(), metrics.KnativeDesiredPodsQuery(name)); len(v) > 0 {
			if n := v[len(v)-1]; n < 0.5 {
				data.Scale = "idle · 0 pods"
			} else {
				data.Scale = fmt.Sprintf("%.0f running", n)
			}
		}
	}
	s.render(w, "function-detail", data)
}
