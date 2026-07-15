package kube

// The resources the console reads and writes, with just enough of each
// object's schema to render a page. Every accessor below is one GET against a
// list endpoint — compare these URLs with what `kubectl get ... -v=8` prints
// and you'll see the portal does exactly what kubectl does.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"time"
)

// objMeta is the tiny slice of ObjectMeta we care about.
type ObjMeta struct {
	Name              string `json:"name"`
	Namespace         string `json:"namespace"`
	CreationTimestamp string `json:"creationTimestamp"`
}

// condition is the standard Kubernetes status condition shape.
type Condition struct {
	Type    string `json:"type"`
	Status  string `json:"status"`
	Reason  string `json:"reason"`
	Message string `json:"message"`
}

// readiness turns a raw Ready condition into what a human expects on a
// dashboard: green "Ready", or — while the controller is still converging —
// its own progress word ("Creating", "Deploying", ...) in amber. A resource
// that is 10 seconds old is not *failing*, it is *becoming*; a red badge
// would tell the wrong story.
type Readiness struct {
	Label string
	Class string // CSS badge class: "ok" (green) or "meh" (amber)
}

func ReadinessOf(conds []Condition) Readiness {
	for _, c := range conds {
		if c.Type != "Ready" {
			continue
		}
		if c.Status == "True" {
			return Readiness{Label: "Ready", Class: "ok"}
		}
		if c.Reason != "" {
			return Readiness{Label: c.Reason, Class: "meh"}
		}
	}
	return Readiness{Label: "Not ready", Class: "meh"}
}

// ---------------------------------------------------------------- ArgoCD

type ArgoApp struct {
	Metadata ObjMeta `json:"metadata"`
	Status   struct {
		Sync struct {
			Status string `json:"status"`
		} `json:"sync"`
		Health struct {
			Status string `json:"status"`
		} `json:"health"`
	} `json:"status"`
}

func (k *Client) ListArgoApps(ctx context.Context) ([]ArgoApp, error) {
	var list struct {
		Items []ArgoApp `json:"items"`
	}
	err := k.get(ctx, "/apis/argoproj.io/v1alpha1/applications", &list)
	return list.Items, err
}

// ---------------------------------------------------------------- core API

// clusterSummary is a taste of the core ("legacy") API group, which lives
// under /api/v1 rather than /apis/<group>/<version>.
type ClusterSummary struct {
	Namespaces  int
	Pods        int
	PodsRunning int
}

func (k *Client) Summarize(ctx context.Context) (ClusterSummary, error) {
	var s ClusterSummary
	var nsList struct {
		Items []struct{} `json:"items"`
	}
	if err := k.get(ctx, "/api/v1/namespaces", &nsList); err != nil {
		return s, err
	}
	var podList struct {
		Items []struct {
			Status struct {
				Phase string `json:"phase"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := k.get(ctx, "/api/v1/pods", &podList); err != nil {
		return s, err
	}
	s.Namespaces = len(nsList.Items)
	s.Pods = len(podList.Items)
	for _, p := range podList.Items {
		if p.Status.Phase == "Running" {
			s.PodsRunning++
		}
	}
	return s, nil
}

// ---------------------------------------------------------------- CNPG

type CNPGCluster struct {
	Metadata ObjMeta `json:"metadata"`
	Spec     struct {
		Instances int `json:"instances"`
	} `json:"spec"`
	Status struct {
		ReadyInstances int    `json:"readyInstances"`
		Phase          string `json:"phase"`
	} `json:"status"`
}

func (k *Client) ListCNPGClusters(ctx context.Context) ([]CNPGCluster, error) {
	var list struct {
		Items []CNPGCluster `json:"items"`
	}
	err := k.get(ctx, "/apis/postgresql.cnpg.io/v1/clusters", &list)
	return list.Items, err
}

// ---------------------------------------------------------------- Knative

type KnativeService struct {
	Metadata ObjMeta `json:"metadata"`
	Status   struct {
		URL        string      `json:"url"`
		Conditions []Condition `json:"conditions"`
	} `json:"status"`
}

func (s KnativeService) Readiness() Readiness { return ReadinessOf(s.Status.Conditions) }

func (k *Client) ListKnativeServices(ctx context.Context) ([]KnativeService, error) {
	var list struct {
		Items []KnativeService `json:"items"`
	}
	err := k.get(ctx, "/apis/serving.knative.dev/v1/services", &list)
	return list.Items, err
}

// ------------------------------------------------- WorkshopDatabase (XR)

// The self-service database from module 04: a namespaced Crossplane v2
// composite resource. The schema below mirrors the XRD
// (workshopdatabases.platform.cloudbox.io): spec.size is "small" or "medium",
// spec.storageGB is 1–10 GiB.
const (
	xrAPI  = "platform.cloudbox.io/v1alpha1"
	xrKind = "WorkshopDatabase"
	// The namespace the console provisions databases into. Crossplane v2 XRs
	// are namespaced — no cluster-scoped claims anymore.
	XRNamespace = "demo"
	xrPath      = "/apis/platform.cloudbox.io/v1alpha1/namespaces/" + XRNamespace + "/workshopdatabases"
)

type WorkshopDB struct {
	Metadata ObjMeta `json:"metadata"`
	Spec     struct {
		Size      string `json:"size"`
		StorageGB int    `json:"storageGB"`
	} `json:"spec"`
	Status struct {
		Conditions []Condition `json:"conditions"`
	} `json:"status"`
}

func (d WorkshopDB) Readiness() Readiness { return ReadinessOf(d.Status.Conditions) }

func (k *Client) ListWorkshopDatabases(ctx context.Context) ([]WorkshopDB, error) {
	var list struct {
		Items []WorkshopDB `json:"items"`
	}
	err := k.get(ctx, xrPath, &list)
	return list.Items, err
}

// dnsName matches RFC 1123 labels — the same rule the API server enforces on
// metadata.name, checked here so users get a friendly error instead of a 422.
var dnsName = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$`)

// ValidName reports whether s is a name we are willing to put in a URL path.
func ValidName(s string) bool { return dnsName.MatchString(s) }

// BuildWorkshopDatabase constructs the XR document by hand. This is the whole
// trick behind "self-service platform APIs": creating a database is one POST
// of ~10 lines of JSON, which Crossplane then expands into a CNPG Postgres
// cluster and an S3 bucket (see lab/04's Composition).
func BuildWorkshopDatabase(name, size string, storageGB int) ([]byte, error) {
	if !ValidName(name) {
		return nil, fmt.Errorf("name %q must be a lowercase DNS label (a-z, 0-9, '-')", name)
	}
	if size != "small" && size != "medium" {
		return nil, fmt.Errorf("size must be small or medium, got %q", size)
	}
	if storageGB < 1 || storageGB > 10 {
		return nil, fmt.Errorf("storageGB must be 1-10, got %d", storageGB)
	}
	xr := map[string]any{
		"apiVersion": xrAPI,
		"kind":       xrKind,
		"metadata":   map[string]any{"name": name, "namespace": XRNamespace},
		"spec":       map[string]any{"size": size, "storageGB": storageGB},
	}
	return json.Marshal(xr)
}

func (k *Client) CreateWorkshopDatabase(ctx context.Context, name, size string, storageGB int) error {
	body, err := BuildWorkshopDatabase(name, size, storageGB)
	if err != nil {
		return err
	}
	return k.do(ctx, http.MethodPost, xrPath, bytes.NewReader(body), nil)
}

func (k *Client) DeleteWorkshopDatabase(ctx context.Context, name string) error {
	if !ValidName(name) {
		return fmt.Errorf("invalid name %q", name)
	}
	return k.do(ctx, http.MethodDelete, xrPath+"/"+name, nil, nil)
}

// ------------------------------------------------- Argo Workflows (CI)

// A Workflow is one Argo Workflows run — the in-cluster CI object from module
// 07. Nothing new happens here: a Workflow is an argoproj.io CRD just like an
// Application, so listing runs is the exact same authenticated GET-a-list the
// portal already does everywhere else, with the same token and the same helper.
const (
	// The build *pods* run in the PSA-privileged `builds` namespace (the
	// controller's --managed-namespace); the controller itself lives in ns
	// `argo`. The Workflow objects we list live in `builds`.
	WorkflowNamespace = "builds"
	workflowsPath     = "/apis/argoproj.io/v1alpha1/namespaces/" + WorkflowNamespace + "/workflows"
)

type Workflow struct {
	Metadata ObjMeta `json:"metadata"`
	Status   struct {
		Phase      string `json:"phase"`      // Pending | Running | Succeeded | Failed | Error
		StartedAt  string `json:"startedAt"`  // RFC3339, set once the controller starts the run
		FinishedAt string `json:"finishedAt"` // RFC3339, empty while the run is still going
	} `json:"status"`
}

func (k *Client) ListArgoWorkflows(ctx context.Context) ([]Workflow, error) {
	var list struct {
		Items []Workflow `json:"items"`
	}
	err := k.get(ctx, workflowsPath, &list)
	return list.Items, err
}

// PhaseClass maps an Argo Workflows phase onto the console's badge colors —
// the same green / amber / red vocabulary ArgoCD health uses elsewhere.
func (w Workflow) PhaseClass() string {
	switch w.Status.Phase {
	case "Succeeded":
		return "ok"
	case "Failed", "Error":
		return "bad"
	default: // Pending, Running, or not-yet-set: in-between, amber.
		return "meh"
	}
}

// Duration is the run's wall-clock time: finished − started for a completed
// run, or elapsed-so-far for one still going. The API hands back RFC3339
// strings; parsing them here keeps the template logic-free. A run the
// controller hasn't started yet renders a dash.
func (w Workflow) Duration() string {
	start, err := time.Parse(time.RFC3339, w.Status.StartedAt)
	if err != nil {
		return "—"
	}
	end := time.Now()
	if w.Status.FinishedAt != "" {
		if t, err := time.Parse(time.RFC3339, w.Status.FinishedAt); err == nil {
			end = t
		}
	}
	d := end.Sub(start).Round(time.Second)
	if d < 0 {
		return "—"
	}
	return d.String()
}
