package kube

// The Application XR (PRD-0003, the golden path): one namespaced Crossplane v2
// composite that composes a Knative workload + a WorkshopDatabase + an S3
// bucket, with DATABASE_URL/S3_* injected. This is the console's headline
// self-service action — "deploy an app with its dependencies" from one form —
// and it's the same platform.cloudbox.io API the golden-path lab teaches. Like
// WorkshopDatabase and Functions, the portal writes the XR by hand and lets
// Crossplane converge (console-direct write, per DR-0004).

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
)

const (
	appAPI  = "platform.cloudbox.io/v1alpha1"
	appKind = "Application"
)

// appPath builds the Application collection path for a project namespace (or the
// cluster-wide path when ns == "").
func appPath(ns string) string {
	if ns == "" {
		return "/apis/platform.cloudbox.io/v1alpha1/applications"
	}
	return "/apis/platform.cloudbox.io/v1alpha1/namespaces/" + ns + "/applications"
}

// Application mirrors the XRD (applications.platform.cloudbox.io): an image, its
// autoscaling bounds, extra env, and the database/bucket toggles. Status carries
// the Crossplane Ready condition.
type Application struct {
	Metadata ObjMeta `json:"metadata"`
	Spec     struct {
		Image    string `json:"image"`
		Replicas struct {
			Min int `json:"min"`
			Max int `json:"max"`
		} `json:"replicas"`
		Env []struct {
			Name  string `json:"name"`
			Value string `json:"value"`
		} `json:"env"`
		Database bool `json:"database"`
		Bucket   bool `json:"bucket"`
	} `json:"spec"`
	Status struct {
		Conditions []Condition `json:"conditions"`
	} `json:"status"`
}

func (a Application) Readiness() Readiness { return ReadinessOf(a.Status.Conditions) }

// AppEnv is one plain env var on the workload.
type AppEnv struct{ Name, Value string }

// AppOpts is what the New-application form collects.
type AppOpts struct {
	Image            string
	MinScale         int
	MaxScale         int
	Env              []AppEnv
	Database, Bucket bool
}

// ListApplications lists apps in a project namespace (or across all projects
// when ns == "").
func (k *Client) ListApplications(ctx context.Context, ns string) ([]Application, error) {
	var list struct {
		Items []Application `json:"items"`
	}
	err := k.get(ctx, appPath(ns), &list)
	return list.Items, err
}

// BuildApplication hand-writes the Application XR document — the whole "deploy
// an app + its dependencies" request is this ~15 lines of JSON, which Crossplane
// expands into a ksvc, a database and a bucket (see the golden-path Composition).
func BuildApplication(ns, name string, opts AppOpts) ([]byte, error) {
	if !ValidName(name) {
		return nil, fmt.Errorf("name %q must be a lowercase DNS label (a-z, 0-9, '-')", name)
	}
	if opts.Image == "" {
		return nil, fmt.Errorf("image is required")
	}
	if opts.MaxScale < 1 {
		opts.MaxScale = 3
	}
	if opts.MinScale < 0 {
		opts.MinScale = 0
	}
	spec := map[string]any{
		"image": opts.Image,
		"replicas": map[string]any{
			"min": opts.MinScale,
			"max": opts.MaxScale,
		},
		"database": opts.Database,
		"bucket":   opts.Bucket,
	}
	if env := appEnvList(opts.Env); len(env) > 0 {
		spec["env"] = env
	}
	xr := map[string]any{
		"apiVersion": appAPI,
		"kind":       appKind,
		"metadata":   map[string]any{"name": name, "namespace": ns},
		"spec":       spec,
	}
	return json.Marshal(xr)
}

func appEnvList(env []AppEnv) []any {
	out := make([]any, 0, len(env))
	for _, e := range env {
		if e.Name == "" {
			continue
		}
		out = append(out, map[string]any{"name": e.Name, "value": e.Value})
	}
	return out
}

func (k *Client) CreateApplication(ctx context.Context, ns, name string, opts AppOpts) error {
	body, err := BuildApplication(ns, name, opts)
	if err != nil {
		return err
	}
	return k.do(ctx, http.MethodPost, appPath(ns), bytes.NewReader(body), nil)
}

func (k *Client) DeleteApplication(ctx context.Context, ns, name string) error {
	if !ValidName(name) {
		return fmt.Errorf("invalid name %q", name)
	}
	return k.do(ctx, http.MethodDelete, appPath(ns)+"/"+name, nil, nil)
}
