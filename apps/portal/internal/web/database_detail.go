package web

// The database detail page — the "click a resource, see everything about
// it" pattern every real console has. Nothing here is portal magic: the
// conditions come from the resources' own status, the events from the API
// server's activity log, and the connection info from CNPG's documented
// conventions (a `<cluster>-app` Secret, an `app` database and user).

import (
	"fmt"
	"net/http"

	"cloudbox.io/portal/internal/kube"
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
}

func handleDatabaseDetail(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !kube.ValidName(name) {
		http.NotFound(w, r)
		return
	}

	data := dbDetailData{Name: name}

	db, err := s.Kube.GetWorkshopDatabase(r.Context(), name)
	if err != nil {
		s.renderError(w, err)
		return
	}
	data.DB = db

	cluster, clusterName, err := s.Kube.GetCNPGCluster(r.Context(), name)
	if err != nil {
		s.renderError(w, err)
		return
	}
	data.Cluster = cluster
	data.ClusterName = clusterName

	// Events for the backing cluster object — same log the Activity page
	// reads, narrowed with a fieldSelector instead of filtering client-side.
	events, err := s.Kube.ListEvents(r.Context(),
		"/api/v1/namespaces/demo/events", "involvedObject.name="+clusterName)
	if err == nil {
		if len(events) > 20 {
			events = events[:20]
		}
		data.Events = events
	}

	data.Secret = clusterName + "-app"
	data.Psql = fmt.Sprintf("kubectl -n demo exec -it %s-1 -- psql -U app app", clusterName)
	data.GrafanaURL = grafanaExplore(s.GrafanaURL, "prometheus",
		fmt.Sprintf(`cnpg_backends_total{cluster=%q, namespace="demo"}`, clusterName))

	s.render(w, "database-detail", data)
}
