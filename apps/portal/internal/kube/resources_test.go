package kube

import (
	"encoding/json"
	"testing"
)

// The XR the portal creates must match the XRD in lab/04-self-service —
// group platform.cloudbox.io, version v1alpha1, kind WorkshopDatabase,
// namespaced, with spec.size and spec.storageGB.
func TestBuildWorkshopDatabase(t *testing.T) {
	raw, err := BuildWorkshopDatabase("my-db", "medium", 5)
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
			StorageGB int    `json:"storageGB"`
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
	if xr.Spec.Size != "medium" || xr.Spec.StorageGB != 5 {
		t.Errorf("spec = %+v", xr.Spec)
	}
}

func TestBuildWorkshopDatabaseValidation(t *testing.T) {
	cases := []struct {
		name      string
		size      string
		storageGB int
	}{
		{"UPPER", "small", 1},     // not a DNS label
		{"has space", "small", 1}, // not a DNS label
		{"", "small", 1},          // empty name
		{"ok", "xlarge", 1},       // size outside the XRD enum
		{"ok", "small", 0},        // below XRD minimum
		{"ok", "small", 11},       // above XRD maximum
	}
	for _, c := range cases {
		if _, err := BuildWorkshopDatabase(c.name, c.size, c.storageGB); err == nil {
			t.Errorf("BuildWorkshopDatabase(%q, %q, %d): expected error, got none", c.name, c.size, c.storageGB)
		}
	}
}
