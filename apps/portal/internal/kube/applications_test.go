package kube

import (
	"encoding/json"
	"strings"
	"testing"
)

// The Application XR the portal writes must match the XRD in
// gitops/components/application-xr: group platform.cloudbox.io, kind
// Application, spec.image + replicas{min,max} + env + database/bucket.
func TestBuildApplication(t *testing.T) {
	raw, err := BuildApplication("demo", "my-app", AppOpts{
		Image:    "ghcr.io/acme/api:v2",
		MinScale: 1, MaxScale: 5,
		Env:      []AppEnv{{Name: "LOG_LEVEL", Value: "info"}, {Name: "", Value: "dropped"}},
		Database: true, Bucket: false,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var xr struct {
		APIVersion string                           `json:"apiVersion"`
		Kind       string                           `json:"kind"`
		Metadata   struct{ Name, Namespace string } `json:"metadata"`
		Spec       struct {
			Image    string                         `json:"image"`
			Replicas struct{ Min, Max int }         `json:"replicas"`
			Env      []struct{ Name, Value string } `json:"env"`
			Database bool                           `json:"database"`
			Bucket   bool                           `json:"bucket"`
		} `json:"spec"`
	}
	if err := json.Unmarshal(raw, &xr); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if xr.APIVersion != "platform.cloudbox.io/v1alpha1" || xr.Kind != "Application" {
		t.Errorf("apiVersion/kind = %q/%q", xr.APIVersion, xr.Kind)
	}
	if xr.Metadata.Name != "my-app" || xr.Metadata.Namespace != "demo" {
		t.Errorf("metadata = %+v", xr.Metadata)
	}
	if xr.Spec.Image != "ghcr.io/acme/api:v2" || xr.Spec.Replicas.Min != 1 || xr.Spec.Replicas.Max != 5 {
		t.Errorf("spec = %+v", xr.Spec)
	}
	if !xr.Spec.Database || xr.Spec.Bucket {
		t.Errorf("database/bucket = %v/%v, want true/false", xr.Spec.Database, xr.Spec.Bucket)
	}
	if len(xr.Spec.Env) != 1 || xr.Spec.Env[0].Name != "LOG_LEVEL" {
		t.Errorf("env = %+v, want exactly the non-blank LOG_LEVEL", xr.Spec.Env)
	}
}

// GiteaRepoURL is the anti-SSRF / offline guardrail: only <org>/<repo> in the
// in-cluster Gitea resolves; anything that could escape the host is rejected.
func TestGiteaRepoURL(t *testing.T) {
	got, err := GiteaRepoURL("team-a/myapp")
	if err != nil {
		t.Fatalf("valid repo rejected: %v", err)
	}
	if got != "http://gitea-http.gitea.svc.cluster.local:3000/team-a/myapp.git" {
		t.Errorf("URL = %q", got)
	}
	for _, bad := range []string{
		"", "onlyorg", "a/b/c", "../evil", "http://evil.com/x",
		"team-a/my repo", "team-a/my@repo", "//evil",
	} {
		if _, err := GiteaRepoURL(bad); err == nil {
			t.Errorf("GiteaRepoURL(%q): expected rejection", bad)
		}
	}
}

// The app build workflow reuses the shared build-and-push primitive with an
// app-prefixed image and the source branch/path the developer chose.
func TestBuildAppWorkflowShape(t *testing.T) {
	raw, err := buildWorkflow("build-app-web-", "http://gitea-http.gitea.svc.cluster.local:3000/team-a/web.git", "main", "svc", appSourceImage(fnPushHost, "web", "b7"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var wf struct {
		Metadata struct {
			GenerateName string `json:"generateName"`
			Namespace    string `json:"namespace"`
		} `json:"metadata"`
		Spec struct {
			WorkflowTemplateRef struct{ Name string } `json:"workflowTemplateRef"`
			Arguments           struct {
				Parameters []struct{ Name, Value string } `json:"parameters"`
			} `json:"arguments"`
		} `json:"spec"`
	}
	if err := json.Unmarshal(raw, &wf); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if wf.Metadata.GenerateName != "build-app-web-" || wf.Metadata.Namespace != "builds" {
		t.Errorf("metadata = %+v", wf.Metadata)
	}
	if wf.Spec.WorkflowTemplateRef.Name != "build-and-push" {
		t.Errorf("templateRef = %q", wf.Spec.WorkflowTemplateRef.Name)
	}
	p := map[string]string{}
	for _, kv := range wf.Spec.Arguments.Parameters {
		p[kv.Name] = kv.Value
	}
	if p["image"] != "zot.zot.svc.cluster.local:5000/app-web:b7" || p["path"] != "svc" || p["branch"] != "main" {
		t.Errorf("params = %+v", p)
	}
	// The workload must pull from the node host (skip-list), not the push host,
	// at the SAME unique tag the build pushed.
	if AppSourcePullImage("web", "b7") != "localhost:30500/app-web:b7" {
		t.Errorf("pull image = %q", AppSourcePullImage("web", "b7"))
	}
}

// A source-built Application records its repo in annotations so Redeploy can
// rebuild it; a prebuilt-image app carries none.
func TestApplicationSourceAnnotations(t *testing.T) {
	raw, err := BuildApplication("demo", "web", AppOpts{
		Image:  "localhost:30500/app-web:b7",
		Source: &AppSource{Repo: "http://gitea/team-a/web.git", Branch: "main", Path: "svc"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var app Application
	if err := json.Unmarshal(raw, &app); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	repo, branch, path, ok := app.Source()
	if !ok || repo != "http://gitea/team-a/web.git" || branch != "main" || path != "svc" {
		t.Errorf("Source() = %q/%q/%q ok=%v", repo, branch, path, ok)
	}
	// A prebuilt-image app has no source.
	raw2, _ := BuildApplication("demo", "img", AppOpts{Image: "ghcr.io/x/y:1"})
	var app2 Application
	_ = json.Unmarshal(raw2, &app2)
	if _, _, _, ok := app2.Source(); ok {
		t.Error("a prebuilt-image app must not report a source")
	}
}

// BuildApplication defaults the scale bounds and requires an image + valid name.
func TestBuildApplicationValidation(t *testing.T) {
	// Missing image.
	if _, err := BuildApplication("demo", "ok", AppOpts{}); err == nil {
		t.Error("expected an error when image is empty")
	}
	// Bad name.
	if _, err := BuildApplication("demo", "Bad_Name", AppOpts{Image: "x"}); err == nil {
		t.Error("expected an error for a non-DNS name")
	}
	// Defaults: max<1 → 3, min<0 → 0.
	raw, err := BuildApplication("demo", "ok", AppOpts{Image: "x", MinScale: -1, MaxScale: 0})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if s := string(raw); !strings.Contains(s, `"min":0`) || !strings.Contains(s, `"max":3`) {
		t.Errorf("scale defaults not applied: %s", s)
	}
}

// ValidGitBranch guards the branch that becomes the Argo build's git revision:
// permissive for real branch names, but no whitespace, shell metacharacters or
// path traversal — parity with the repo's orgRepoRe guard. The default "main"
// (and the CI rehearsal's branch=main) must pass.
func TestValidGitBranch(t *testing.T) {
	for _, ok := range []string{"main", "feature/foo", "release-1.2", "v2.0", "a_b", "topic/sub-topic"} {
		if err := ValidGitBranch(ok); err != nil {
			t.Errorf("ValidGitBranch(%q): unexpected rejection: %v", ok, err)
		}
	}
	for _, bad := range []string{
		"", "..", "../etc", "/abs", "a/", "a b", "a;b", "a$(x)", "-flag",
		"foo/../bar", ".hidden", "trailing.", "a\tb", "a\nb",
	} {
		if err := ValidGitBranch(bad); err == nil {
			t.Errorf("ValidGitBranch(%q): expected rejection", bad)
		}
	}
}

// ValidSourcePath guards the source subpath that becomes workingDir /src/<path>
// in the build: a relative subpath only — the default "." and the rehearsal's
// path=lab/07-ci/app must pass; a leading '/' or any ".." segment is rejected.
func TestValidSourcePath(t *testing.T) {
	for _, ok := range []string{".", "sub/dir", "lab/07-ci/app", "svc", "a_b/c-d.e"} {
		if err := ValidSourcePath(ok); err != nil {
			t.Errorf("ValidSourcePath(%q): unexpected rejection: %v", ok, err)
		}
	}
	for _, bad := range []string{
		"", "..", "../etc", "/abs", "foo/../bar", "a b", "a;b", "a$(x)", "sub/..",
	} {
		if err := ValidSourcePath(bad); err == nil {
			t.Errorf("ValidSourcePath(%q): expected rejection", bad)
		}
	}
}
