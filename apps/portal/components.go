package main

// The Components page: statuspage-style health for every platform capability.
//
// The idea is dead simple — each capability lives in its own namespace (one
// namespace per component is a repo convention), so "is Gitea healthy?"
// reduces to "are the workloads in namespace gitea ready?". We fetch three
// cluster-wide lists (Deployments, StatefulSets, DaemonSets) and group them
// by namespace. That is 3 GETs per page load — a real controller would open
// a WATCH, but a portal polling every 10 seconds has no need to.

import (
	"context"
	"net/http"
)

// component is one row on the page. The list is fixed and ordered the way
// the workshop builds the platform up; Catalog names the file to copy into
// gitops/apps/ when the component is not installed yet ("" = installed by
// the bootstrap, not the catalog).
type component struct {
	Title       string
	Namespace   string
	Description string
	Catalog     string
}

var componentCatalog = []component{
	{"Cilium & cluster core", "kube-system", "CNI, DNS, and the control plane's helpers", ""},
	{"Storage", "local-path-storage", "local-path-provisioner — every PVC lands on your disk", ""},
	{"Observability", "observability", "grafana/otel-lgtm — traces, metrics, logs, one pod", ""},
	{"Gitea", "gitea", "the in-cluster git server ArgoCD deploys from", ""},
	{"ArgoCD", "argocd", "GitOps engine — syncs this very platform", ""},
	{"CloudNativePG", "cnpg-system", "Postgres operator behind the database self-service", "cnpg-operator.yaml"},
	{"RustFS", "rustfs", "S3-compatible object storage (bucket: images)", "rustfs.yaml"},
	{"Zot registry", "zot", "OCI registry for in-cluster image builds", "zot.yaml"},
	{"Crossplane", "crossplane-system", "composes WorkshopDatabases into real resources", "crossplane.yaml"},
	{"Knative Serving", "knative-serving", "scale-to-zero serverless runtime", "knative-serving.yaml"},
	{"Kourier", "kourier-system", "Knative's ingress gateway", "knative-serving.yaml"},
	{"Knative Eventing", "knative-eventing", "the CloudEvent broker wiring the capstone", "knative-eventing.yaml"},
	{"Argo Workflows", "argo", "runs the in-cluster CI pipelines", "argo-workflows.yaml"},
	{"Builds", "builds", "rootless BuildKit — where module 07's images are built", "argo-workflows.yaml"},
	{"Cloudbox Console", "portal", "this portal", "portal.yaml"},
	{"Picture pipeline", "pipeline", "uploader + resizer + broker (capstone)", "picture-pipeline.yaml"},
	{"Backstage", "backstage", "the presenter's portal demo — heavyweight, enable last", "backstage.yaml"},
	{"Demo workloads", "demo", "your WorkshopDatabases and experiments live here", ""},
}

// nsHealth counts the workloads in one namespace and how many of them are
// fully ready. A workload scaled to zero (Knative between requests!) counts
// as ready — wanting zero and having zero is success, not failure.
type nsHealth struct {
	Ready, Total int
}

// workload is the tiny slice of Deployment/StatefulSet/DaemonSet status we
// need. The three kinds spell "desired" and "ready" differently; the unused
// pair decodes as zero, so max() picks the right one either way.
type workload struct {
	Metadata objMeta `json:"metadata"`
	Status   struct {
		Replicas               int `json:"replicas"`               // deploy + sts
		ReadyReplicas          int `json:"readyReplicas"`          // deploy + sts
		DesiredNumberScheduled int `json:"desiredNumberScheduled"` // daemonset
		NumberReady            int `json:"numberReady"`            // daemonset
	} `json:"status"`
}

func (k *kubeClient) namespaceWorkloads(ctx context.Context) (map[string]nsHealth, error) {
	health := map[string]nsHealth{}
	for _, path := range []string{
		"/apis/apps/v1/deployments",
		"/apis/apps/v1/statefulsets",
		"/apis/apps/v1/daemonsets",
	} {
		var list struct {
			Items []workload `json:"items"`
		}
		if err := k.get(ctx, path, &list); err != nil {
			return nil, err
		}
		for _, w := range list.Items {
			desired := max(w.Status.Replicas, w.Status.DesiredNumberScheduled)
			ready := max(w.Status.ReadyReplicas, w.Status.NumberReady)
			h := health[w.Metadata.Namespace]
			h.Total++
			if ready >= desired {
				h.Ready++
			}
			health[w.Metadata.Namespace] = h
		}
	}
	return health, nil
}

// componentRow is a component joined with the live state of its namespace.
type componentRow struct {
	component
	Ready, Total int
	Status       string // Operational | Degraded | Down | Not installed
	Class        string // dot color: ok | meh | bad | off
	Hint         string // shown muted after the description
}

func componentRows(health map[string]nsHealth) []componentRow {
	rows := make([]componentRow, 0, len(componentCatalog))
	for _, c := range componentCatalog {
		h := health[c.Namespace]
		row := componentRow{component: c, Ready: h.Ready, Total: h.Total}
		switch {
		case h.Total == 0:
			row.Status, row.Class = "Not installed", "off"
			if c.Catalog != "" {
				row.Hint = "enable gitops/catalog/" + c.Catalog
			}
		case h.Ready == h.Total:
			row.Status, row.Class = "Operational", "ok"
		case h.Ready > 0:
			row.Status, row.Class = "Degraded", "meh"
		default:
			row.Status, row.Class = "Down", "bad"
		}
		rows = append(rows, row)
	}
	return rows
}

// ---------------------------------------------------------------- handlers

type componentsData struct {
	Running     []componentRow // installed, whatever their health
	Marketplace []componentRow // not installed — each one catalog file away
	Flash       flash
}

// splitRows separates what runs from what is still on the shelf — the
// "marketplace" framing every cloud console uses, except this marketplace
// is a directory of YAML files and everything in it costs kr 0,00.
func splitRows(rows []componentRow) componentsData {
	var d componentsData
	for _, row := range rows {
		if row.Total > 0 {
			d.Running = append(d.Running, row)
		} else {
			d.Marketplace = append(d.Marketplace, row)
		}
	}
	return d
}

func (s *server) handleComponents(w http.ResponseWriter, r *http.Request) {
	health, err := s.kube.namespaceWorkloads(r.Context())
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "components", splitRows(componentRows(health)))
}

// handleComponentsList is the fragment htmx polls every 10s — same
// self-healing pattern as the databases list: errors become a flash, the
// polling attributes stay in the DOM.
func (s *server) handleComponentsList(w http.ResponseWriter, r *http.Request) {
	health, err := s.kube.namespaceWorkloads(r.Context())
	if err != nil {
		s.render(w, "components-list", componentsData{Flash: errorFlash("API error: " + err.Error())})
		return
	}
	s.render(w, "components-list", splitRows(componentRows(health)))
}
