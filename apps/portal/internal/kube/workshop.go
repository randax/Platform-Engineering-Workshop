package kube

// Workshop progress rules — the cluster-state half of the Workshop page.
// Snapshot is everything the rules need; the web layer gathers it (some of
// it comes from S3, not from here) and EvaluateModules turns it into the
// checklist. Each module has one deliberately simple rule below — this is a
// hint, not a judge: ./verify.sh in each lab folder is the authoritative
// check, and module 05 can't be inferred at all.

import (
	"context"
	"strings"
)

// Snapshot is everything the rules need, gathered in one place. Reads that
// fail because a CRD or bucket does not exist yet are treated as "zero of
// them" — that just means the module hasn't happened, and is exactly what
// this page is here to show.
type Snapshot struct {
	Apps          map[string]ArgoApp // ArgoCD Applications by name
	NodesTotal    int
	NodesReady    int
	KubeProxyPods int  // Cilium must have replaced these (module 01)
	GiteaHealthy  bool // all workloads in ns gitea ready
	CNPGInDemo    bool // a CNPG Cluster exists in ns demo
	WDBCount      int  // WorkshopDatabases in ns demo
	KsvcReady     bool // ≥1 Knative Service Ready outside ns pipeline
	ThumbsCount   int  // objects under thumbs/ in the images bucket
}

// AppHealthy reports whether the named ArgoCD Application exists, and
// whether ArgoCD considers it Healthy.
func (s Snapshot) AppHealthy(name string) (exists, healthy bool) {
	a, ok := s.Apps[name]
	return ok, ok && a.Status.Health.Status == "Healthy"
}

// ------------------------------------------------------------- kube reads

// NodeReadiness: a node is Ready when its Ready condition is True — the
// same condition shape every other resource uses.
func (k *Client) NodeReadiness(ctx context.Context) (total, ready int, err error) {
	var list struct {
		Items []struct {
			Status struct {
				Conditions []Condition `json:"conditions"`
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

// CountKubeSystemPods counts pods in kube-system whose name starts with the
// given prefix (kube-proxy has no stable label across distros; the name is
// the honest check on a lab cluster).
func (k *Client) CountKubeSystemPods(ctx context.Context, prefix string) (int, error) {
	var list struct {
		Items []struct {
			Metadata ObjMeta `json:"metadata"`
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

type ModuleRow struct {
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

// EvaluateModules applies one rule per module. Keep these rules honest and
// boring — every clever inference is a lie waiting to happen.
func EvaluateModules(s Snapshot) []ModuleRow {
	rows := make([]ModuleRow, 0, 10)
	add := func(number, title string, met, total int, next string) {
		status, class := progress(met, total)
		if status == "Done" {
			next = ""
		}
		rows = append(rows, ModuleRow{number, title, status, class, next})
	}

	// 00 — you are reading this page inside the portal, inside the cluster.
	add("00", "Setup", 1, 1, "")

	// 01 — all nodes Ready AND no kube-proxy pods (Cilium replaced it).
	add("01", "Cluster",
		countTrue(s.NodesTotal > 0 && s.NodesReady == s.NodesTotal, s.NodesTotal > 0 && s.KubeProxyPods == 0), 2,
		"scripts/create-cluster.sh — see lab/01-cluster")

	// 02 — the app-of-apps root exists AND Gitea's workloads are ready.
	platformExists, _ := s.AppHealthy("platform")
	add("02", "GitOps",
		countTrue(platformExists, s.GiteaHealthy), 2,
		"scripts/bootstrap-gitops.sh — see lab/02-gitops")

	// 03 — cnpg-operator + rustfs Healthy AND a CNPG cluster runs in demo.
	_, cnpgOK := s.AppHealthy("cnpg-operator")
	_, rustfsOK := s.AppHealthy("rustfs")
	add("03", "Data services",
		countTrue(cnpgOK, rustfsOK, s.CNPGInDemo), 3,
		"cp gitops/catalog/{cnpg-operator,rustfs}.yaml gitops/apps/ && git push — see lab/03-data")

	// 04 — crossplane Healthy AND at least one WorkshopDatabase exists.
	_, xpOK := s.AppHealthy("crossplane")
	add("04", "Self-service",
		countTrue(xpOK, s.WDBCount > 0), 2,
		"enable gitops/catalog/crossplane.yaml, then create a database on the Databases page — see lab/04-self-service")

	// 05 — cannot be inferred from state: the fault is injected and fixed.
	rows = append(rows, ModuleRow{"05", "Debug with AI", "Manual check", "info",
		"fault injection is self-checked; run lab/05-debug-with-ai/verify.sh"})

	// 06 — knative-serving Healthy AND ≥1 ksvc Ready outside ns pipeline.
	_, servingOK := s.AppHealthy("knative-serving")
	add("06", "Serverless",
		countTrue(servingOK, s.KsvcReady), 2,
		"enable gitops/catalog/knative-serving.yaml, then deploy a service — see lab/06-serverless")

	// 07 — zot + argo-workflows Healthy. The build itself is only checked
	// by lab/07-ci/verify.sh; this page can't see inside the pipeline run.
	_, zotOK := s.AppHealthy("zot")
	_, wfOK := s.AppHealthy("argo-workflows")
	add("07", "In-cluster CI",
		countTrue(zotOK, wfOK), 2,
		"enable gitops/catalog/{zot,argo-workflows}.yaml; the build is checked by lab/07-ci/verify.sh")

	// 08 — the portal Application is Healthy (it is serving you either way).
	_, portalOK := s.AppHealthy("portal")
	add("08", "Portal",
		countTrue(portalOK), 1,
		"enable gitops/catalog/portal.yaml — see lab/08-portal")

	// 09 — eventing + pipeline Healthy AND the resizer has produced a thumbnail.
	_, evOK := s.AppHealthy("knative-eventing")
	_, ppOK := s.AppHealthy("picture-pipeline")
	add("09", "Capstone",
		countTrue(evOK, ppOK, s.ThumbsCount > 0), 3,
		"enable gitops/catalog/{knative-eventing,picture-pipeline}.yaml, then upload an image in the Gallery — see lab/09-capstone")

	return rows
}
