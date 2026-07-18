package kube

// Projects (PRD-0011): a Project maps 1:1 to a Kubernetes namespace, labelled so
// the console can enumerate them. Creating one is console-direct (DR-0004): the
// portal POSTs a labelled Namespace + a RoleBinding that binds the shared
// `portal-tenant` ClusterRole to the portal ServiceAccount, so the portal can
// then create the self-service resources (databases, functions, apps) inside it.
// The portal holds only a scoped, git-delivered grant to do this (namespaces +
// rolebindings + bind on portal-tenant) — it still cannot grant itself anything
// broader. "Grant via git; act via console."

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
)

// ProjectLabel marks a namespace as a console Project. New projects get it; the
// selector lists namespaces carrying it.
const ProjectLabel = "platform.cloudbox.io/project"

// tenantClusterRole is the ClusterRole bound (per project) that lets the portal
// manage self-service resources in that namespace. Defined + granted via git
// (lab/08-portal/portal-projects-access.yaml).
const tenantClusterRole = "portal-tenant"

// ListProjects returns the namespaces labelled as projects.
func (k *Client) ListProjects(ctx context.Context) ([]string, error) {
	var list struct {
		Items []struct {
			Metadata ObjMeta `json:"metadata"`
		} `json:"items"`
	}
	err := k.get(ctx, "/api/v1/namespaces?labelSelector="+ProjectLabel+"%3Dtrue", &list)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(list.Items))
	for _, it := range list.Items {
		names = append(names, it.Metadata.Name)
	}
	return names, nil
}

// CreateProject provisions a project namespace and binds the portal's tenant
// grant into it, so the console can immediately create resources there.
func (k *Client) CreateProject(ctx context.Context, name string) error {
	if !ValidName(name) {
		return fmt.Errorf("name %q must be a lowercase DNS label (a-z, 0-9, '-')", name)
	}
	ns := map[string]any{
		"apiVersion": "v1",
		"kind":       "Namespace",
		"metadata": map[string]any{
			"name":   name,
			"labels": map[string]any{ProjectLabel: "true"},
		},
	}
	body, err := json.Marshal(ns)
	if err != nil {
		return err
	}
	if err := k.do(ctx, http.MethodPost, "/api/v1/namespaces", bytes.NewReader(body), nil); err != nil {
		return err
	}
	// Bind the tenant grant so the portal can create self-service resources here.
	rb := map[string]any{
		"apiVersion": "rbac.authorization.k8s.io/v1",
		"kind":       "RoleBinding",
		"metadata":   map[string]any{"name": tenantClusterRole, "namespace": name},
		"roleRef": map[string]any{
			"apiGroup": "rbac.authorization.k8s.io",
			"kind":     "ClusterRole",
			"name":     tenantClusterRole,
		},
		"subjects": []any{
			map[string]any{"kind": "ServiceAccount", "name": "portal", "namespace": "portal"},
		},
	}
	body, err = json.Marshal(rb)
	if err != nil {
		return err
	}
	return k.do(ctx, http.MethodPost, "/apis/rbac.authorization.k8s.io/v1/namespaces/"+name+"/rolebindings", bytes.NewReader(body), nil)
}

// DeleteProject removes a project namespace, which cascades to everything
// composed inside it (databases, functions, apps).
func (k *Client) DeleteProject(ctx context.Context, name string) error {
	if !ValidName(name) {
		return fmt.Errorf("invalid name %q", name)
	}
	// Guard: only delete namespaces that ARE console projects (carry the label).
	// The portal's grant is cluster-wide namespace delete — Kubernetes RBAC can't
	// scope a verb to label-selected objects — so this app-layer check is the only
	// thing stopping a stray/typo'd name (kube-system, argocd, gitea) from being
	// deleted. Refuse anything not explicitly marked a project.
	var ns struct {
		Metadata struct {
			Labels map[string]string `json:"labels"`
		} `json:"metadata"`
	}
	if err := k.get(ctx, "/api/v1/namespaces/"+name, &ns); err != nil {
		return err
	}
	if ns.Metadata.Labels[ProjectLabel] != "true" {
		return fmt.Errorf("%q isn't a console project (missing the %s=true label) — refusing to delete it", name, ProjectLabel)
	}
	return k.do(ctx, http.MethodDelete, "/api/v1/namespaces/"+name, nil, nil)
}
