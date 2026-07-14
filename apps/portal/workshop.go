package main

// The Workshop page: a checklist inferring module progress from live cluster
// state. Each module has one deliberately simple rule below — this page is a
// hint, not a judge: ./verify.sh in each lab folder is the authoritative
// check (it looks much closer), and module 05 can't be inferred at all.

import (
	"context"
	"net/http"
	"strings"
)

// snapshot is everything the rules need, gathered in one place. Reads that
// fail because a CRD or bucket does not exist yet are treated as "zero of
// them" — that just means the module hasn't happened, and is exactly what
// this page is here to show.
type snapshot struct {
	apps          map[string]argoApp // ArgoCD Applications by name
	nodesTotal    int
	nodesReady    int
	kubeProxyPods int  // Cilium must have replaced these (module 01)
	giteaHealthy  bool // all workloads in ns gitea ready
	cnpgInDemo    bool // a CNPG Cluster exists in ns demo
	wdbCount      int  // WorkshopDatabases in ns demo
	ksvcReady     bool // ≥1 Knative Service Ready outside ns pipeline
	thumbsCount   int  // objects under thumbs/ in the images bucket
}

// appHealthy reports whether the named ArgoCD Application exists, and
// whether ArgoCD considers it Healthy.
func (s snapshot) appHealthy(name string) (exists, healthy bool) {
	a, ok := s.apps[name]
	return ok, ok && a.Status.Health.Status == "Healthy"
}

func (s *server) workshopSnapshot(ctx context.Context) (snapshot, error) {
	snap := snapshot{apps: map[string]argoApp{}}

	// The backbone: if we cannot list Applications, show the error page.
	apps, err := s.kube.listArgoApps(ctx)
	if err != nil {
		return snap, err
	}
	for _, a := range apps {
		snap.apps[a.Metadata.Name] = a
	}

	// Everything below is best-effort (see the type comment).
	snap.nodesTotal, snap.nodesReady, _ = s.kube.nodeReadiness(ctx)
	snap.kubeProxyPods, _ = s.kube.countKubeSystemPods(ctx, "kube-proxy")

	if health, err := s.kube.namespaceWorkloads(ctx); err == nil {
		g := health["gitea"]
		snap.giteaHealthy = g.Total > 0 && g.Ready == g.Total
	}
	if clusters, err := s.kube.listCNPGClusters(ctx); err == nil {
		for _, c := range clusters {
			if c.Metadata.Namespace == "demo" {
				snap.cnpgInDemo = true
			}
		}
	}
	if dbs, err := s.kube.listWorkshopDatabases(ctx); err == nil {
		snap.wdbCount = len(dbs)
	}
	if svcs, err := s.kube.listKnativeServices(ctx); err == nil {
		for _, k := range svcs {
			if k.Metadata.Namespace != "pipeline" && k.Readiness().Class == "ok" {
				snap.ksvcReady = true
			}
		}
	}
	snap.thumbsCount, _ = s.s3.countPrefix(ctx, "thumbs/")
	return snap, nil
}

// ------------------------------------------------------------- kube reads

// nodeReadiness: a node is Ready when its Ready condition is True — the
// same condition shape every other resource uses.
func (k *kubeClient) nodeReadiness(ctx context.Context) (total, ready int, err error) {
	var list struct {
		Items []struct {
			Status struct {
				Conditions []condition `json:"conditions"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := k.get(ctx, "/api/v1/nodes", &list); err != nil {
		return 0, 0, err
	}
	for _, n := range list.Items {
		total++
		for _, c := range n.Status.Conditions {
			if c.Type == "Ready" && c.Status == "True" {
				ready++
			}
		}
	}
	return total, ready, nil
}

// countKubeSystemPods counts pods in kube-system whose name starts with the
// given prefix (kube-proxy has no stable label across distros; the name is
// the honest check on a lab cluster).
func (k *kubeClient) countKubeSystemPods(ctx context.Context, prefix string) (int, error) {
	var list struct {
		Items []struct {
			Metadata objMeta `json:"metadata"`
		} `json:"items"`
	}
	if err := k.get(ctx, "/api/v1/namespaces/kube-system/pods", &list); err != nil {
		return 0, err
	}
	n := 0
	for _, p := range list.Items {
		if strings.HasPrefix(p.Metadata.Name, prefix) {
			n++
		}
	}
	return n, nil
}

// ------------------------------------------------------------ the modules

type moduleRow struct {
	Number string
	Title  string
	Status string // Done | In progress | Not started | Manual check
	Class  string // badge color: ok | meh | off | info
	Next   string // one-line pointer, hidden once Done
}

// progress maps "n of total conditions hold" onto a status.
func progress(met, total int) (string, string) {
	switch {
	case met == total:
		return "Done", "ok"
	case met > 0:
		return "In progress", "meh"
	default:
		return "Not started", "off"
	}
}

func countTrue(conds ...bool) int {
	n := 0
	for _, c := range conds {
		if c {
			n++
		}
	}
	return n
}

// evaluateModules applies one rule per module. Keep these rules honest and
// boring — every clever inference is a lie waiting to happen.
func evaluateModules(s snapshot) []moduleRow {
	rows := make([]moduleRow, 0, 10)
	add := func(number, title string, met, total int, next string) {
		status, class := progress(met, total)
		if status == "Done" {
			next = ""
		}
		rows = append(rows, moduleRow{number, title, status, class, next})
	}

	// 00 — you are reading this page inside the portal, inside the cluster.
	add("00", "Setup", 1, 1, "")

	// 01 — all nodes Ready AND no kube-proxy pods (Cilium replaced it).
	add("01", "Cluster",
		countTrue(s.nodesTotal > 0 && s.nodesReady == s.nodesTotal, s.nodesTotal > 0 && s.kubeProxyPods == 0), 2,
		"scripts/create-cluster.sh — see lab/01-cluster")

	// 02 — the app-of-apps root exists AND Gitea's workloads are ready.
	platformExists, _ := s.appHealthy("platform")
	add("02", "GitOps",
		countTrue(platformExists, s.giteaHealthy), 2,
		"scripts/bootstrap-gitops.sh — see lab/02-gitops")

	// 03 — cnpg-operator + rustfs Healthy AND a CNPG cluster runs in demo.
	_, cnpgOK := s.appHealthy("cnpg-operator")
	_, rustfsOK := s.appHealthy("rustfs")
	add("03", "Data services",
		countTrue(cnpgOK, rustfsOK, s.cnpgInDemo), 3,
		"cp gitops/catalog/{cnpg-operator,rustfs}.yaml gitops/apps/ && git push — see lab/03-data")

	// 04 — crossplane Healthy AND at least one WorkshopDatabase exists.
	_, xpOK := s.appHealthy("crossplane")
	add("04", "Self-service",
		countTrue(xpOK, s.wdbCount > 0), 2,
		"enable gitops/catalog/crossplane.yaml, then create a database on the Databases page — see lab/04-self-service")

	// 05 — cannot be inferred from state: the fault is injected and fixed.
	rows = append(rows, moduleRow{"05", "Debug with AI", "Manual check", "info",
		"fault injection is self-checked; run lab/05-debug-with-ai/verify.sh"})

	// 06 — knative-serving Healthy AND ≥1 ksvc Ready outside ns pipeline.
	_, servingOK := s.appHealthy("knative-serving")
	add("06", "Serverless",
		countTrue(servingOK, s.ksvcReady), 2,
		"enable gitops/catalog/knative-serving.yaml, then deploy a service — see lab/06-serverless")

	// 07 — zot + argo-workflows Healthy. The build itself is only checked
	// by lab/07-ci/verify.sh; this page can't see inside the pipeline run.
	_, zotOK := s.appHealthy("zot")
	_, wfOK := s.appHealthy("argo-workflows")
	add("07", "In-cluster CI",
		countTrue(zotOK, wfOK), 2,
		"enable gitops/catalog/{zot,argo-workflows}.yaml; the build is checked by lab/07-ci/verify.sh")

	// 08 — the portal Application is Healthy (it is serving you either way).
	_, portalOK := s.appHealthy("portal")
	add("08", "Portal",
		countTrue(portalOK), 1,
		"enable gitops/catalog/portal.yaml — see lab/08-portal")

	// 09 — eventing + pipeline Healthy AND the resizer has produced a thumbnail.
	_, evOK := s.appHealthy("knative-eventing")
	_, ppOK := s.appHealthy("picture-pipeline")
	add("09", "Capstone",
		countTrue(evOK, ppOK, s.thumbsCount > 0), 3,
		"enable gitops/catalog/{knative-eventing,picture-pipeline}.yaml, then upload an image in the Gallery — see lab/09-capstone")

	return rows
}

// ---------------------------------------------------------------- handlers

type workshopData struct {
	Modules []moduleRow
	Flash   flash
}

func (s *server) handleWorkshop(w http.ResponseWriter, r *http.Request) {
	snap, err := s.workshopSnapshot(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "workshop", workshopData{Modules: evaluateModules(snap)})
}

// handleWorkshopList: the 10s-polled fragment, self-healing like the others.
func (s *server) handleWorkshopList(w http.ResponseWriter, r *http.Request) {
	snap, err := s.workshopSnapshot(r.Context())
	if err != nil {
		s.render(w, "workshop-list", workshopData{Flash: errorFlash("API error: " + err.Error())})
		return
	}
	s.render(w, "workshop-list", workshopData{Modules: evaluateModules(snap)})
}
