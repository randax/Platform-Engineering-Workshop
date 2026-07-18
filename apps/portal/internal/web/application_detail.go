package web

// The Application detail page — the composition hub. An Application is the
// richest self-service object (it composes a workload + a database + a bucket +,
// for source-built apps, a repo), so it earns a detail view like Components and
// Databases have: its status and *why* when unhealthy (DR-0005, moved off the
// list), the composed resources CROSS-LINKED to their own detail pages (so a
// developer can walk app → its DB → back), the source + Redeploy, live metrics,
// and delete. The list stays a scannable triage table; depth lives here.

import (
	"fmt"
	"html/template"
	"net/http"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/metrics"
)

// composedRef is one resource the Application composed, with a link to its own
// detail page — the navigation that was missing entirely before this page.
type composedRef struct {
	Kind string // Database | Bucket | Workload
	Name string
	Href string // "" = no detail page to link to (yet)
	Note string // a short "what it is / how it's wired" line
}

type appDetailData struct {
	Name      string
	Namespace string
	Found     bool
	Readiness kube.Readiness
	URL       string // the composed ksvc URL, once Ready

	SourceBuilt bool
	Repo        string
	Branch      string

	Composed []composedRef

	// Diagnostics — the "why", here on the detail (not crammed on the list).
	Why      string
	Diag     kube.Diagnostics
	ShowDiag bool

	// Case file — the single-shot agent investigation (module 10). ShowCaseFile
	// is set for an unhealthy app; AgentAvailable reflects whether the kagent
	// capability is present (else the affordance renders locked).
	ShowCaseFile   bool
	AgentAvailable bool

	// Monitoring — the workload's request rate + latency, best-effort.
	Telemetry  bool
	ReqSpark   template.HTML
	LatSpark   template.HTML
	LatNow     string
	MetricsURL string
}

func handleApplicationDetail(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !kube.ValidName(name) {
		http.NotFound(w, r)
		return
	}
	ns := s.activeProject(r)
	app, err := s.Kube.GetApplication(r.Context(), ns, name)
	if err != nil {
		s.renderError(w, err)
		return
	}
	data := appDetailData{Name: name, Namespace: ns}
	if app == nil {
		s.render(w, "application-detail", data) // Found == false → "no such app"
		return
	}
	data.Found = true
	data.Readiness = app.Readiness()
	if data.Readiness.Class == "ok" {
		data.URL = fmt.Sprintf("http://%s.%s.127.0.0.1.sslip.io:31080", name, ns)
	}
	repo, branch, _, sourceBuilt := app.Source()
	data.SourceBuilt, data.Repo, data.Branch = sourceBuilt, repo, branch

	// The composition names things deterministically (see application-xr): the
	// workload ksvc is <name>, the WorkshopDatabase is <name>, the bucket is
	// <name>-data. v1 always composes the DB + bucket regardless of the toggles.
	data.Composed = []composedRef{
		{Kind: "Workload", Name: name, Note: "Knative Service — scales to zero; serves the URL above"},
		{Kind: "Database", Name: name, Href: "/databases/" + name, Note: "Postgres, injected as DATABASE_URL"},
		{Kind: "Bucket", Name: name + "-data", Href: "/buckets/" + name + "-data", Note: "S3 bucket, injected as S3_*"},
	}

	// Diagnose here when the app isn't Ready (DR-0005).
	if data.Readiness.Class != "ok" {
		data.Why = app.Why()
		if diag, derr := s.Kube.NamespaceDiagnostics(r.Context(), ns); derr == nil {
			data.Diag = diag
			data.ShowDiag = data.Why != "" || !diag.Empty()
		}
		// Offer the Case file agent investigation on an unhealthy app (module 10).
		// It renders locked unless the kagent capability is present.
		data.ShowCaseFile = true
		data.AgentAvailable = agentAvailable(s)
	}

	// The workload's metrics (job = cloudbox-<name>), once observability is on —
	// best-effort, same degrade-to-empty pattern as the Functions page.
	job := "cloudbox-" + name
	if health, herr := s.Kube.NamespaceWorkloads(r.Context()); herr == nil && health["observability"].Ready > 0 && s.Prom != nil {
		data.Telemetry = true
		data.MetricsURL = grafanaTraces(s.GrafanaURL, job)
		if v, _ := s.Prom.QueryRange(r.Context(), metrics.RequestRateQuery(job)); len(v) > 0 {
			data.ReqSpark = metrics.Sparkline(v, "request rate")
		}
		if v, _ := s.Prom.QueryRange(r.Context(), metrics.LatencyAvgQuery(job)); len(v) > 0 {
			data.LatSpark = metrics.Sparkline(v, "avg latency")
			data.LatNow = fmt.Sprintf("%.0f ms", v[len(v)-1]*1000)
		}
	}

	s.render(w, "application-detail", data)
}
