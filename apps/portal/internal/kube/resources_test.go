package kube

import (
	"encoding/json"
	"testing"
)

// The XR the portal creates must match the XRD in lab/04-self-service —
// group platform.cloudbox.io, version v1alpha1, kind WorkshopDatabase,
// namespaced, with a single knob: spec.size (the T-shirt, PRD-0006).
func TestBuildWorkshopDatabase(t *testing.T) {
	raw, err := BuildWorkshopDatabase("my-db", "large")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var xr struct {
		APIVersion string `json:"apiVersion"`
		Kind       string `json:"kind"`
		Metadata   struct {
			Name      string `json:"name"`
			Namespace string `json:"namespace"`
		} `json:"metadata"`
		Spec struct {
			Size      string `json:"size"`
			StorageGB int    `json:"storageGB"` // must be absent (0) — the leak is closed
		} `json:"spec"`
	}
	if err := json.Unmarshal(raw, &xr); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if xr.APIVersion != "platform.cloudbox.io/v1alpha1" {
		t.Errorf("apiVersion = %q", xr.APIVersion)
	}
	if xr.Kind != "WorkshopDatabase" {
		t.Errorf("kind = %q", xr.Kind)
	}
	if xr.Metadata.Name != "my-db" || xr.Metadata.Namespace != "demo" {
		t.Errorf("metadata = %+v", xr.Metadata)
	}
	if xr.Spec.Size != "large" {
		t.Errorf("spec.size = %q, want large", xr.Spec.Size)
	}
	if xr.Spec.StorageGB != 0 {
		t.Errorf("spec.storageGB should be absent (T-shirt bundles storage), got %d", xr.Spec.StorageGB)
	}
}

func TestBuildWorkshopDatabaseValidation(t *testing.T) {
	cases := []struct {
		name string
		size string
	}{
		{"UPPER", "small"},     // not a DNS label
		{"has space", "small"}, // not a DNS label
		{"", "small"},          // empty name
		{"ok", "xlarge"},       // size outside the XRD enum
		{"ok", ""},             // empty size
	}
	for _, c := range cases {
		if _, err := BuildWorkshopDatabase(c.name, c.size); err == nil {
			t.Errorf("BuildWorkshopDatabase(%q, %q): expected error, got none", c.name, c.size)
		}
	}
}
