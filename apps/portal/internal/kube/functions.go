package kube

// New Function (issue #58): the console's Lambda-style create-flow. One form
// submit fans out into two hand-written objects that together turn source into
// a running, scale-to-zero function URL — no CLI, no client-go:
//
//   1. an Argo Workflows `Workflow` (ns builds) that references the module-07
//      `build-and-push` WorkflowTemplate: git-clone → BuildKit → push to Zot.
//   2. a Knative `Service` (ns demo) whose image is that same artifact, seen
//      from the node (localhost:30500).
//
// We create BOTH up front and let Kubernetes converge — no console-side state,
// matching the rest of this stateless, poll-and-render portal. The ksvc's first
// revision sits in ImagePullBackOff until the build pushes the image, then the
// kubelet's automatic pull retry brings it Ready. The Builds and Services pages
// (already built) show the two halves' progress.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
)

const (
	// The two vantage points on one artifact (module 07's core lesson):
	// BuildKit PUSHES to Zot over cluster DNS; the kubelet PULLS the same image
	// over Zot's NodePort. localhost:30500 is in Knative's
	// registries-skipping-tag-resolving list, so a tag-only ksvc image is
	// admitted without digest resolution and converges once the build lands.
	fnPushHost = "zot.zot.svc.cluster.local:5000"
	fnPullHost = "localhost:30500"

	// Functions deploy as Knative Services in the same demo namespace the
	// WorkshopDatabase self-service uses — the one namespace the attendee grants
	// the portal write access to.
	KsvcNamespace = "demo"
	ksvcPath      = "/apis/serving.knative.dev/v1/namespaces/" + KsvcNamespace + "/services"
)

// functionImage builds the "fn-<name>:v1" image reference at the given host.
// The fn- prefix namespaces built functions away from hand-deployed ksvcs and
// makes the Services page instantly legible ("that one came from a build").
func functionImage(host, name string) string {
	return fmt.Sprintf("%s/fn-%s:v1", host, name)
}

// BuildFunctionWorkflow hand-writes the Argo `Workflow` that builds the
// function's image. generateName (not name) so each submit mints a fresh run,
// exactly like `kubectl create` on lab/07-ci/workflow-run.yaml — which is why
// we POST to the collection, never PUT/apply.
func BuildFunctionWorkflow(name, repo, path string) ([]byte, error) {
	if !ValidName(name) {
		return nil, fmt.Errorf("name %q must be a lowercase DNS label (a-z, 0-9, '-')", name)
	}
	wf := map[string]any{
		"apiVersion": "argoproj.io/v1alpha1",
		"kind":       "Workflow",
		"metadata": map[string]any{
			"generateName": "build-fn-" + name + "-",
			"namespace":    WorkflowNamespace,
		},
		"spec": map[string]any{
			"workflowTemplateRef": map[string]any{"name": "build-and-push"},
			"arguments": map[string]any{
				"parameters": []any{
					map[string]any{"name": "repo", "value": repo},
					map[string]any{"name": "path", "value": path},
					map[string]any{"name": "image", "value": functionImage(fnPushHost, name)},
				},
			},
		},
	}
	return json.Marshal(wf)
}

func (k *Client) CreateFunctionWorkflow(ctx context.Context, name, repo, path string) error {
	body, err := BuildFunctionWorkflow(name, repo, path)
	if err != nil {
		return err
	}
	return k.do(ctx, http.MethodPost, workflowsPath, bytes.NewReader(body), nil)
}

// BuildFunctionService hand-writes the Knative `Service` — the same minimal
// shape as lab/06-serverless/hello-ksvc.yaml, but pointed at the freshly-built
// image via the node-side host. The short autoscaling window keeps the
// scale-to-zero demo watchable.
func BuildFunctionService(name string) ([]byte, error) {
	if !ValidName(name) {
		return nil, fmt.Errorf("name %q must be a lowercase DNS label (a-z, 0-9, '-')", name)
	}
	svc := map[string]any{
		"apiVersion": "serving.knative.dev/v1",
		"kind":       "Service",
		"metadata":   map[string]any{"name": "fn-" + name, "namespace": KsvcNamespace},
		"spec": map[string]any{
			"template": map[string]any{
				"metadata": map[string]any{
					"annotations": map[string]any{"autoscaling.knative.dev/window": "30s"},
				},
				"spec": map[string]any{
					"containers": []any{
						map[string]any{
							"image": functionImage(fnPullHost, name),
							"resources": map[string]any{
								"requests": map[string]any{"memory": "32Mi", "cpu": "25m"},
							},
						},
					},
				},
			},
		},
	}
	return json.Marshal(svc)
}

func (k *Client) CreateFunctionService(ctx context.Context, name string) error {
	body, err := BuildFunctionService(name)
	if err != nil {
		return err
	}
	return k.do(ctx, http.MethodPost, ksvcPath, bytes.NewReader(body), nil)
}
