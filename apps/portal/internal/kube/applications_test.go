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
