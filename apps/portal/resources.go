package main

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
)

// objMeta is the tiny slice of ObjectMeta we care about.
type objMeta struct {
	Name              string `json:"name"`
	Namespace         string `json:"namespace"`
	CreationTimestamp string `json:"creationTimestamp"`
}

// condition is the standard Kubernetes status condition shape.
type condition struct {
	Type   string `json:"type"`
	Status string `json:"status"`
	Reason string `json:"reason"`
}

func readyCondition(conds []condition) string {
	for _, c := range conds {
		if c.Type == "Ready" {
			return c.Status
		}
	}
	return "Unknown"
}

// ---------------------------------------------------------------- ArgoCD

type argoApp struct {
	Metadata objMeta `json:"metadata"`
	Status   struct {
		Sync struct {
			Status string `json:"status"`
		} `json:"sync"`
		Health struct {
			Status string `json:"status"`
		} `json:"health"`
	} `json:"status"`
}

func (k *kubeClient) listArgoApps(ctx context.Context) ([]argoApp, error) {
	var list struct {
		Items []argoApp `json:"items"`
	}
	err := k.get(ctx, "/apis/argoproj.io/v1alpha1/applications", &list)
	return list.Items, err
}

// ---------------------------------------------------------------- core API

// clusterSummary is a taste of the core ("legacy") API group, which lives
// under /api/v1 rather than /apis/<group>/<version>.
type clusterSummary struct {
	Namespaces  int
	Pods        int
	PodsRunning int
}

func (k *kubeClient) summarize(ctx context.Context) (clusterSummary, error) {
	var s clusterSummary
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

type cnpgCluster struct {
	Metadata objMeta `json:"metadata"`
	Spec     struct {
		Instances int `json:"instances"`
	} `json:"spec"`
	Status struct {
		ReadyInstances int    `json:"readyInstances"`
		Phase          string `json:"phase"`
	} `json:"status"`
}

func (k *kubeClient) listCNPGClusters(ctx context.Context) ([]cnpgCluster, error) {
	var list struct {
		Items []cnpgCluster `json:"items"`
	}
	err := k.get(ctx, "/apis/postgresql.cnpg.io/v1/clusters", &list)
	return list.Items, err
}

// ---------------------------------------------------------------- Knative

type knativeService struct {
	Metadata objMeta `json:"metadata"`
	Status   struct {
		URL        string      `json:"url"`
		Conditions []condition `json:"conditions"`
	} `json:"status"`
}

func (s knativeService) Ready() string { return readyCondition(s.Status.Conditions) }

func (k *kubeClient) listKnativeServices(ctx context.Context) ([]knativeService, error) {
	var list struct {
		Items []knativeService `json:"items"`
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
	xrNamespace = "demo"
	xrPath      = "/apis/platform.cloudbox.io/v1alpha1/namespaces/" + xrNamespace + "/workshopdatabases"
)

type workshopDB struct {
	Metadata objMeta `json:"metadata"`
	Spec     struct {
		Size      string `json:"size"`
		StorageGB int    `json:"storageGB"`
	} `json:"spec"`
	Status struct {
		Conditions []condition `json:"conditions"`
	} `json:"status"`
}

func (d workshopDB) Ready() string { return readyCondition(d.Status.Conditions) }

func (k *kubeClient) listWorkshopDatabases(ctx context.Context) ([]workshopDB, error) {
	var list struct {
		Items []workshopDB `json:"items"`
	}
	err := k.get(ctx, xrPath, &list)
	return list.Items, err
}

// dnsName matches RFC 1123 labels — the same rule the API server enforces on
// metadata.name, checked here so users get a friendly error instead of a 422.
var dnsName = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$`)

// buildWorkshopDatabase constructs the XR document by hand. This is the whole
// trick behind "self-service platform APIs": creating a database is one POST
// of ~10 lines of JSON, which Crossplane then expands into a CNPG Postgres
// cluster and an S3 bucket (see lab/04's Composition).
func buildWorkshopDatabase(name, size string, storageGB int) ([]byte, error) {
	if !dnsName.MatchString(name) {
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
		"metadata":   map[string]any{"name": name, "namespace": xrNamespace},
		"spec":       map[string]any{"size": size, "storageGB": storageGB},
	}
	return json.Marshal(xr)
}

func (k *kubeClient) createWorkshopDatabase(ctx context.Context, name, size string, storageGB int) error {
	body, err := buildWorkshopDatabase(name, size, storageGB)
	if err != nil {
		return err
	}
	return k.do(ctx, http.MethodPost, xrPath, bytes.NewReader(body), nil)
}

func (k *kubeClient) deleteWorkshopDatabase(ctx context.Context, name string) error {
	if !dnsName.MatchString(name) {
		return fmt.Errorf("invalid name %q", name)
	}
	return k.do(ctx, http.MethodDelete, xrPath+"/"+name, nil, nil)
}
