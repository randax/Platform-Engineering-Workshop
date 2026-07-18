package web

// The database detail page — the "click a resource, see everything about
// it" pattern every real console has. Nothing here is portal magic: the
// conditions come from the resources' own status, the events from the API
// server's activity log, and the connection info from CNPG's documented
// conventions (a `<cluster>-app` Secret, an `app` database and user).

import (
	"fmt"
	"html/template"
	"net/http"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/metrics"
)

type dbDetailData struct {
	Name        string
	DB          *kube.WorkshopDB        // nil: no XR (an unmanaged cluster, or already deleted)
	Cluster     *kube.CNPGClusterDetail // nil: Crossplane hasn't composed it yet
	ClusterName string                  // the CNPG cluster backing this database
	Events      []kube.Event
	Secret      string // CNPG convention: <cluster>-app holds the credentials
	Psql        string // ready-to-paste one-liner
	GrafanaURL  string // Explore link with a PromQL placeholder prefilled

	// Diagnostics — the "why" when the database isn't Ready (DR-0005): the
	// WorkshopDB failing condition + the instance pods' trouble.
	Why      string
	Diag     kube.Diagnostics
	ShowDiag bool

	// Monitoring — CNPG metrics, populated only when observability is collecting.
	Telemetry  bool
	ConnSpark  template.HTML
	ConnNow    string
	CacheSpark template.HTML
	CacheNow   string
	SizeNow    string
}

func handleDatabaseDetail(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !kube.ValidName(name) {
		http.NotFound(w, r)
		return
	}

	ns := s.activeProject(r)
	data := dbDetailData{Name: name}

	db, err := s.Kube.GetWorkshopDatabase(r.Context(), ns, name)
	if err != nil {
		s.renderError(w, err)
		return
	}
	data.DB = db

	cluster, clusterName, err := s.Kube.GetCNPGCluster(r.Context(), ns, name)
	if err != nil {
		s.renderError(w, err)
		return
	}
	data.Cluster = cluster
	data.ClusterName = clusterName

	// Events for the backing cluster object — same log the Activity page
	// reads, narrowed with a fieldSelector instead of filtering client-side.
	events, err := s.Kube.ListEvents(r.Context(),
		"/api/v1/namespaces/"+ns+"/events", "involvedObject.name="+clusterName)
	if err == nil {
		if len(events) > 20 {
			events = events[:20]
		}
		data.Events = events
	}

	// Diagnose when the database isn't Ready (DR-0005): the Crossplane cause +
	// the CNPG instance pods' trouble. Best-effort; never breaks the page.
	if db != nil && db.Readiness().Class != "ok" {
		data.Why = db.Why()
		if diag, derr := s.Kube.NamespaceDiagnostics(r.Context(), ns); derr == nil {
			data.Diag = diag
		}
		data.ShowDiag = data.Why != "" || !data.Diag.Empty()
	}

	data.Secret = clusterName + "-app"
	data.Psql = fmt.Sprintf("kubectl -n %s exec -it %s-1 -- psql -U app app", ns, clusterName)
	data.GrafanaURL = grafanaExplore(s.GrafanaURL, "victoriametrics", metrics.CNPGConnectionsQuery(clusterName))

	// Monitoring: CNPG's own metrics for this cluster, once the observability
	// stack is collecting (the cnpg scrape tags every series cnpg_cluster=…).
	if health, herr := s.Kube.NamespaceWorkloads(r.Context()); herr == nil && health["observability"].Ready > 0 && s.Prom != nil {
		data.Telemetry = true
		if v, _ := s.Prom.QueryRange(r.Context(), metrics.CNPGConnectionsQuery(clusterName)); len(v) > 0 {
			data.ConnSpark = metrics.Sparkline(v, "connections")
			data.ConnNow = fmt.Sprintf("%.0f", v[len(v)-1])
		}
		if v, _ := s.Prom.QueryRange(r.Context(), metrics.CNPGCacheHitQuery(clusterName)); len(v) > 0 {
			data.CacheSpark = metrics.Sparkline(v, "cache hit ratio")
			data.CacheNow = fmt.Sprintf("%.1f%%", v[len(v)-1])
		}
		if v, _ := s.Prom.QueryRange(r.Context(), metrics.CNPGSizeQuery(clusterName)); len(v) > 0 {
			data.SizeNow = humanBytes(v[len(v)-1])
		}
	}

	s.render(w, "database-detail", data)
}
