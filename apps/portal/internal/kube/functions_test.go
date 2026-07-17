package kube

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestBuildFunctionWorkflow(t *testing.T) {
	raw, err := BuildFunctionWorkflow("greeter", "http://gitea-http.gitea.svc.cluster.local:3000/cloudbox/platform.git", "lab/07-ci/app")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var wf struct {
		APIVersion string `json:"apiVersion"`
		Kind       string `json:"kind"`
		Metadata   struct {
			GenerateName string `json:"generateName"`
			Namespace    string `json:"namespace"`
			Name         string `json:"name"` // must be empty — generateName mints it
		} `json:"metadata"`
		Spec struct {
			WorkflowTemplateRef struct {
				Name string `json:"name"`
			} `json:"workflowTemplateRef"`
			Arguments struct {
				Parameters []struct {
					Name  string `json:"name"`
					Value string `json:"value"`
				} `json:"parameters"`
			} `json:"arguments"`
		} `json:"spec"`
	}
	if err := json.Unmarshal(raw, &wf); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if wf.APIVersion != "argoproj.io/v1alpha1" || wf.Kind != "Workflow" {
		t.Errorf("apiVersion/kind = %q/%q", wf.APIVersion, wf.Kind)
	}
	if wf.Metadata.GenerateName != "build-fn-greeter-" || wf.Metadata.Namespace != "builds" {
		t.Errorf("metadata = %+v", wf.Metadata)
	}
	if wf.Metadata.Name != "" {
		t.Errorf("Name must be empty so generateName applies, got %q", wf.Metadata.Name)
	}
	if wf.Spec.WorkflowTemplateRef.Name != "build-and-push" {
		t.Errorf("workflowTemplateRef = %q", wf.Spec.WorkflowTemplateRef.Name)
	}
	params := map[string]string{}
	for _, p := range wf.Spec.Arguments.Parameters {
		params[p.Name] = p.Value
	}
	// The build PUSHES to Zot via cluster DNS — never the node-side NodePort.
	if got := params["image"]; got != "zot.zot.svc.cluster.local:5000/fn-greeter:v1" {
		t.Errorf("build image = %q, want cluster-DNS push host", got)
	}
	if params["path"] != "lab/07-ci/app" {
		t.Errorf("path param = %q", params["path"])
	}
	if !strings.HasPrefix(params["repo"], "http://gitea-http.gitea.svc.cluster.local") {
		t.Errorf("repo param = %q, must be an in-cluster Gitea URL", params["repo"])
	}
}

func TestBuildFunctionService(t *testing.T) {
	raw, err := BuildFunctionService("greeter", FnOpts{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var svc struct {
		APIVersion string `json:"apiVersion"`
		Kind       string `json:"kind"`
		Metadata   struct {
			Name      string `json:"name"`
			Namespace string `json:"namespace"`
		} `json:"metadata"`
		Spec struct {
			Template struct {
				Metadata struct {
					Annotations map[string]string `json:"annotations"`
				} `json:"metadata"`
				Spec struct {
					Containers []struct {
						Image string `json:"image"`
					} `json:"containers"`
				} `json:"spec"`
			} `json:"template"`
		} `json:"spec"`
	}
	if err := json.Unmarshal(raw, &svc); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if svc.APIVersion != "serving.knative.dev/v1" || svc.Kind != "Service" {
		t.Errorf("apiVersion/kind = %q/%q", svc.APIVersion, svc.Kind)
	}
	if svc.Metadata.Name != "fn-greeter" || svc.Metadata.Namespace != "demo" {
		t.Errorf("metadata = %+v", svc.Metadata)
	}
	// The kubelet PULLS via Zot's NodePort. This host MUST be in Knative's
	// registries-skipping-tag-resolving list, or the ksvc fails at admission —
	// so it must be the localhost:30500 form, NOT the cluster-DNS push host.
	img := svc.Spec.Template.Spec.Containers[0].Image
	if img != "localhost:30500/fn-greeter:v1" {
		t.Errorf("ksvc image = %q, want node-side pull host localhost:30500", img)
	}
	if strings.Contains(img, "svc.cluster.local") {
		t.Errorf("ksvc image %q uses the cluster-DNS push host — the kubelet can't resolve that", img)
	}
	if svc.Spec.Template.Metadata.Annotations["autoscaling.knative.dev/window"] != "30s" {
		t.Errorf("missing scale-to-zero window annotation: %+v", svc.Spec.Template.Metadata.Annotations)
	}
	// Default (no opts): scale-to-zero, so NO min-scale pin.
	if _, ok := svc.Spec.Template.Metadata.Annotations["autoscaling.knative.dev/min-scale"]; ok {
		t.Errorf("default function must not pin min-scale (breaks scale-to-zero): %+v", svc.Spec.Template.Metadata.Annotations)
	}
}

// TestBuildFunctionServiceOpts covers the New-function form's optional knobs:
// keep-warm pins min-scale 1, and env vars land on the container (blank rows
// dropped).
func TestBuildFunctionServiceOpts(t *testing.T) {
	raw, err := BuildFunctionService("greeter", FnOpts{
		KeepWarm: true,
		Env:      []FnEnv{{Name: "GREETING", Value: "hei"}, {Name: "", Value: "dropped"}},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var svc struct {
		Spec struct {
			Template struct {
				Metadata struct {
					Annotations map[string]string `json:"annotations"`
				} `json:"metadata"`
				Spec struct {
					Containers []struct {
						Env []struct{ Name, Value string } `json:"env"`
					} `json:"containers"`
				} `json:"spec"`
			} `json:"template"`
		} `json:"spec"`
	}
	if err := json.Unmarshal(raw, &svc); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got := svc.Spec.Template.Metadata.Annotations["autoscaling.knative.dev/min-scale"]; got != "1" {
		t.Errorf("keep-warm must pin min-scale=1, got %q", got)
	}
	env := svc.Spec.Template.Spec.Containers[0].Env
	if len(env) != 1 || env[0].Name != "GREETING" || env[0].Value != "hei" {
		t.Errorf("env = %+v, want exactly the non-blank GREETING=hei", env)
	}
}

func TestBuildFunctionInvalidName(t *testing.T) {
	for _, bad := range []string{"", "Bad_Name", "UPPER", "-lead", "trail-", strings.Repeat("x", 41)} {
		if _, err := BuildFunctionWorkflow(bad, "http://gitea/x.git", "app"); err == nil {
			t.Errorf("BuildFunctionWorkflow(%q): expected validation error", bad)
		}
		if _, err := BuildFunctionService(bad, FnOpts{}); err == nil {
			t.Errorf("BuildFunctionService(%q): expected validation error", bad)
		}
	}
}
