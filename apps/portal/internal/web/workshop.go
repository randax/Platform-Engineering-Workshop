package web

// The Workshop page: module progress inferred from live cluster state. The
// rules live in internal/kube (EvaluateModules); this file gathers their
// input — most of it from the Kubernetes API, one bit (thumbnails) from S3.

import (
	"context"
	"net/http"

	"cloudbox.io/portal/internal/kube"
)

func init() {
	register(Page{
		Weight:     30,
		NavSection: "Platform",
		NavTitle:   "Workshop",
		Path:       "/workshop",
		Handler:    handleWorkshop,
		Extra: []Route{
			{"GET /workshop/list", handleWorkshopList}, // polled by htmx
		},
	})
}

func workshopSnapshot(ctx context.Context, s *Server) (kube.Snapshot, error) {
	snap := kube.Snapshot{Apps: map[string]kube.ArgoApp{}}

	// The backbone: if we cannot list Applications, show the error page.
	apps, err := s.Kube.ListArgoApps(ctx)
	if err != nil {
		return snap, err
	}
	for _, a := range apps {
		snap.Apps[a.Metadata.Name] = a
	}

	// Everything below is best-effort: a missing CRD or bucket just means
	// that module hasn't happened yet (see the Snapshot doc comment).
	snap.NodesTotal, snap.NodesReady, _ = s.Kube.NodeReadiness(ctx)
	snap.KubeProxyPods, _ = s.Kube.CountKubeSystemPods(ctx, "kube-proxy")

	if health, err := s.Kube.NamespaceWorkloads(ctx); err == nil {
		g := health["gitea"]
		snap.GiteaHealthy = g.Total > 0 && g.Ready == g.Total
	}
	if clusters, err := s.Kube.ListCNPGClusters(ctx); err == nil {
		for _, c := range clusters {
			if c.Metadata.Namespace == "demo" {
				snap.CNPGInDemo = true
			}
		}
	}
	if dbs, err := s.Kube.ListWorkshopDatabases(ctx); err == nil {
		snap.WDBCount = len(dbs)
	}
	if svcs, err := s.Kube.ListKnativeServices(ctx); err == nil {
		for _, k := range svcs {
			if k.Metadata.Namespace != "pipeline" && k.Readiness().Class == "ok" {
				snap.KsvcReady = true
			}
		}
	}
	snap.ThumbsCount, _ = s.Store.CountPrefix(ctx, "thumbs/")
	return snap, nil
}

type workshopData struct {
	Modules []kube.ModuleRow
	Flash   flash
}

func handleWorkshop(s *Server, w http.ResponseWriter, r *http.Request) {
	snap, err := workshopSnapshot(r.Context(), s)
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "workshop", workshopData{Modules: kube.EvaluateModules(snap)})
}

// handleWorkshopList: the 10s-polled fragment, self-healing like the others.
func handleWorkshopList(s *Server, w http.ResponseWriter, r *http.Request) {
	snap, err := workshopSnapshot(r.Context(), s)
	if err != nil {
		s.render(w, "workshop-list", workshopData{Flash: errorFlash("API error: " + err.Error())})
		return
	}
	s.render(w, "workshop-list", workshopData{Modules: kube.EvaluateModules(snap)})
}
