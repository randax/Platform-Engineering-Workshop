package main

// The database detail page — the "click a resource, see everything about
// it" pattern every real console has. Nothing here is portal magic: the
// conditions come from the resources' own status, the events from the API
// server's activity log, and the connection info from CNPG's documented
// conventions (a `<cluster>-app` Secret, an `app` database and user).

import (
	"context"
	"fmt"
	"net/http"
)

// cnpgClusterDetail is a richer view of a CNPG Cluster than the list needs.
type cnpgClusterDetail struct {
	Metadata objMeta `json:"metadata"`
	Spec     struct {
		Instances int `json:"instances"`
		Storage   struct {
			Size string `json:"size"`
		} `json:"storage"`
	} `json:"spec"`
	Status struct {
		Phase          string      `json:"phase"`
		ReadyInstances int         `json:"readyInstances"`
		Conditions     []condition `json:"conditions"`
	} `json:"status"`
}

type dbDetailData struct {
	Name        string
	DB          *workshopDB        // nil: no XR (an unmanaged cluster, or already deleted)
	Cluster     *cnpgClusterDetail // nil: Crossplane hasn't composed it yet
	ClusterName string             // the CNPG cluster backing this database
	Events      []k8sEvent
	Secret      string // CNPG convention: <cluster>-app holds the credentials
	Psql        string // ready-to-paste one-liner
	GrafanaURL  string // Explore link with a PromQL placeholder prefilled
}

// getWorkshopDatabase fetches one XR; a 404 means "no such database" and is
// reported as nil, not as an error.
func (k *kubeClient) getWorkshopDatabase(ctx context.Context, name string) (*workshopDB, error) {
	var db workshopDB
	if err := k.get(ctx, xrPath+"/"+name, &db); err != nil {
		if isNotFound(err) {
			return nil, nil
		}
		return nil, err
	}
	return &db, nil
}

// getCNPGCluster looks up the composed cluster. The composition names it
// "<xr>-pg" (see lab/04's Composition); the plain name is tried second so
// the page also works for hand-made CNPG clusters in the demo namespace.
func (k *kubeClient) getCNPGCluster(ctx context.Context, xrName string) (*cnpgClusterDetail, string, error) {
	for _, name := range []string{xrName + "-pg", xrName} {
		var c cnpgClusterDetail
		err := k.get(ctx, "/apis/postgresql.cnpg.io/v1/namespaces/demo/clusters/"+name, &c)
		if err == nil {
			return &c, name, nil
		}
		if !isNotFound(err) {
			return nil, xrName + "-pg", err
		}
	}
	return nil, xrName + "-pg", nil
}

func (s *server) handleDatabaseDetail(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !dnsName.MatchString(name) {
		http.NotFound(w, r)
		return
	}

	data := dbDetailData{Name: name}

	db, err := s.kube.getWorkshopDatabase(r.Context(), name)
	if err != nil {
		s.renderError(w, err)
		return
	}
	data.DB = db

	cluster, clusterName, err := s.kube.getCNPGCluster(r.Context(), name)
	if err != nil {
		s.renderError(w, err)
		return
	}
	data.Cluster = cluster
	data.ClusterName = clusterName

	// Events for the backing cluster object — same log the Activity page
	// reads, narrowed with a fieldSelector instead of filtering client-side.
	events, err := s.kube.listEvents(r.Context(),
		"/api/v1/namespaces/demo/events", "involvedObject.name="+clusterName)
	if err == nil {
		if len(events) > 20 {
			events = events[:20]
		}
		data.Events = events
	}

	data.Secret = clusterName + "-app"
	data.Psql = fmt.Sprintf("kubectl -n demo exec -it %s-1 -- psql -U app app", clusterName)
	data.GrafanaURL = grafanaExplore("prometheus",
		fmt.Sprintf(`cnpg_backends_total{cluster=%q, namespace="demo"}`, clusterName))

	s.render(w, "database-detail", data)
}
