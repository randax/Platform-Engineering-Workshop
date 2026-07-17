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
	"regexp"
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

// ---------------------------------------- deploy from source (app-team CI/CD)

// giteaBase is the in-cluster Gitea host — the ONLY source the platform builds
// from. The offline rule (no github.com) is also the anti-SSRF boundary: the
// app team pushes their code to Gitea, then deploys it; the portal never builds
// an arbitrary URL.
const giteaBase = "http://gitea-http.gitea.svc.cluster.local:3000"

// orgRepoRe validates a "<org>/<repo>" reference as two path segments that each
// start with an alphanumeric/underscore/hyphen — so "." and ".." (path
// traversal) and empty segments can't escape the Gitea host into another URL.
var orgRepoRe = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9._-]*/[A-Za-z0-9_-][A-Za-z0-9._-]*$`)

// GiteaRepoURL builds the clone URL for an in-cluster Gitea repo from
// "<org>/<repo>" (the form the developer pushed their code to).
func GiteaRepoURL(orgRepo string) (string, error) {
	if !orgRepoRe.MatchString(orgRepo) {
		return "", fmt.Errorf("repo must be <org>/<repo> in the in-cluster Gitea, got %q", orgRepo)
	}
	return giteaBase + "/" + orgRepo + ".git", nil
}

// appSourceImage is the built-application image reference. The app- prefix keeps
// source-built app images distinct from fn- function images and hand-deployed
// workloads.
func appSourceImage(host, name string) string {
	return fmt.Sprintf("%s/app-%s:v1", host, name)
}

// AppSourcePullImage is the image an Application built from source should point
// its workload at — the node-side pull host (localhost:30500 is in Knative's
// tag-resolution skip list, so the ksvc is admitted before the build finishes
// and converges once the image lands).
func AppSourcePullImage(name string) string { return appSourceImage(fnPullHost, name) }

// CreateAppBuildWorkflow submits the build that produces an Application's image
// from a Gitea repo. It pushes to Zot over cluster DNS; the composed workload
// pulls the same artifact back via the node host (AppSourcePullImage).
func (k *Client) CreateAppBuildWorkflow(ctx context.Context, name, repo, branch, path string) error {
	if !ValidName(name) {
		return fmt.Errorf("name %q must be a lowercase DNS label (a-z, 0-9, '-')", name)
	}
	body, err := buildWorkflow("build-app-"+name+"-", repo, branch, path, appSourceImage(fnPushHost, name))
	if err != nil {
		return err
	}
	return k.do(ctx, http.MethodPost, workflowsPath, bytes.NewReader(body), nil)
}
