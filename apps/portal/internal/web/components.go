package web

// The Components page: statuspage-style platform health. Each capability
// lives in its own namespace (a repo convention), so "is Gitea healthy?"
// reduces to "are the workloads in namespace gitea ready?".

import (
	"context"
	"net/http"

	"cloudbox.io/portal/internal/kube"
)

func init() {
	register(Page{
		Weight:     20,
		NavSection: "Platform",
		NavTitle:   "Components",
		Path:       "/components",
		Handler:    handleComponents,
		Extra: []Route{
			{"GET /components/list", handleComponentsList}, // polled by htmx
		},
	})
}

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
	{"Observability", "observability", "VictoriaMetrics + VictoriaLogs + VictoriaTraces + Grafana, fed by the OTel Collector", ""},
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

// componentRow is a component joined with the live state of its namespace.
type componentRow struct {
	component
	Ready, Total int
	Status       string // Operational | Degraded | Down | Not installed
	Class        string // dot color: ok | meh | bad | off
	Hint         string // shown muted after the description
}

func componentRows(health map[string]kube.NSHealth) []componentRow {
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
		// Marketplace = catalog-backed AND not yet installed. A component
		// with no catalog file (Cilium, Gitea, ArgoCD, the demo namespace)
		// can't be "enabled", so it always stays in the health section —
		// shown as Down/Not installed if it has no workloads, never offered
		// as "one file away" with a hint pointing at a file that doesn't exist.
		if row.Catalog != "" && row.Total == 0 {
			d.Marketplace = append(d.Marketplace, row)
		} else {
			d.Running = append(d.Running, row)
		}
	}
	return d
}

// workloadLister is the one slice of the kube client this page consumes —
// a consumer-side interface, so its logic can be tested with a fake map
// source instead of an HTTP server.
type workloadLister interface {
	NamespaceWorkloads(ctx context.Context) (map[string]kube.NSHealth, error)
}

func fetchComponents(ctx context.Context, l workloadLister) (componentsData, error) {
	health, err := l.NamespaceWorkloads(ctx)
	if err != nil {
		return componentsData{}, err
	}
	return splitRows(componentRows(health)), nil
}

func handleComponents(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := fetchComponents(r.Context(), s.Kube)
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "components", data)
}

// handleComponentsList is the fragment htmx polls every 10s — same
// self-healing pattern as the databases list: errors become a flash, the
// polling attributes stay in the DOM.
func handleComponentsList(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := fetchComponents(r.Context(), s.Kube)
	if err != nil {
		s.render(w, "components-list", componentsData{Flash: errorFlash("API error: " + err.Error())})
		return
	}
	s.render(w, "components-list", data)
}
