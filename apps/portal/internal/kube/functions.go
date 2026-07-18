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

	// KsvcNamespace is the DEFAULT project functions deploy into — the same
	// default project the rest of self-service uses. With Projects (PRD-0011)
	// the console deploys into whichever project is active.
	KsvcNamespace = "demo"
)

// ksvcPath builds the Knative Service collection path for a project namespace.
func ksvcPath(ns string) string {
	return "/apis/serving.knative.dev/v1/namespaces/" + ns + "/services"
}

// functionImage builds the "fn-<name>:v1" image reference at the given host.
// The fn- prefix namespaces built functions away from hand-deployed ksvcs and
// makes the Services page instantly legible ("that one came from a build").
func functionImage(host, name string) string {
	return fmt.Sprintf("%s/fn-%s:v1", host, name)
}

// buildWorkflow hand-writes an Argo `Workflow` that references the module-07
// `build-and-push` WorkflowTemplate: git-clone → BuildKit → push to Zot. This
// is the platform's ONE reusable CI primitive — the New Function flow and the
// deploy-from-source Application flow both submit one of these. generateName
// (not name) so each submit mints a fresh run, exactly like `kubectl create` on
// lab/07-ci/workflow-run.yaml — which is why we POST to the collection.
func buildWorkflow(generatePrefix, repo, branch, path, image string) ([]byte, error) {
	params := []any{
		map[string]any{"name": "repo", "value": repo},
		map[string]any{"name": "path", "value": path},
		map[string]any{"name": "image", "value": image},
	}
	if branch != "" {
		params = append(params, map[string]any{"name": "branch", "value": branch})
	}
	wf := map[string]any{
		"apiVersion": "argoproj.io/v1alpha1",
		"kind":       "Workflow",
		"metadata": map[string]any{
			"generateName": generatePrefix,
			"namespace":    WorkflowNamespace,
		},
		"spec": map[string]any{
			"workflowTemplateRef": map[string]any{"name": "build-and-push"},
			"arguments":           map[string]any{"parameters": params},
		},
	}
	return json.Marshal(wf)
}

// BuildFunctionWorkflow builds the function's image from a vetted source repo.
func BuildFunctionWorkflow(name, repo, path string) ([]byte, error) {
	if !ValidName(name) {
		return nil, fmt.Errorf("name %q must be a lowercase DNS label (a-z, 0-9, '-')", name)
	}
	return buildWorkflow("build-fn-"+name+"-", repo, "", path, functionImage(fnPushHost, name))
}

func (k *Client) CreateFunctionWorkflow(ctx context.Context, name, repo, path string) error {
	body, err := BuildFunctionWorkflow(name, repo, path)
	if err != nil {
		return err
	}
	return k.do(ctx, http.MethodPost, workflowsPath, bytes.NewReader(body), nil)
}

// FnEnv is one plain environment variable set on the function's container.
type FnEnv struct{ Name, Value string }

// FnOpts carries the optional knobs the New-function form collects beyond the
// name: extra env vars and whether to keep one instance warm (min-scale 1)
// instead of scaling to zero. Zero value = no env, scale-to-zero (the default).
type FnOpts struct {
	Env      []FnEnv
	KeepWarm bool
}

// BuildFunctionService hand-writes the Knative `Service` — the same minimal
// shape as lab/06-serverless/hello-ksvc.yaml, but pointed at the freshly-built
// image via the node-side host. The short autoscaling window keeps the
// scale-to-zero demo watchable; KeepWarm pins min-scale to 1 for a function
// that should never cold-start, and Env appends plain container env vars.
func BuildFunctionService(ns, name string, opts FnOpts) ([]byte, error) {
	if !ValidName(name) {
		return nil, fmt.Errorf("name %q must be a lowercase DNS label (a-z, 0-9, '-')", name)
	}
	annotations := map[string]any{"autoscaling.knative.dev/window": "30s"}
	if opts.KeepWarm {
		// Pin one instance warm — the opposite of the scale-to-zero default,
		// for a function where cold-start latency isn't acceptable.
		annotations["autoscaling.knative.dev/min-scale"] = "1"
	}
	container := map[string]any{
		"image": functionImage(fnPullHost, name),
		"resources": map[string]any{
			"requests": map[string]any{"memory": "32Mi", "cpu": "25m"},
		},
	}
	if env := envList(opts.Env); len(env) > 0 {
		container["env"] = env
	}
	svc := map[string]any{
		"apiVersion": "serving.knative.dev/v1",
		"kind":       "Service",
		"metadata":   map[string]any{"name": "fn-" + name, "namespace": ns},
		"spec": map[string]any{
			"template": map[string]any{
				"metadata": map[string]any{"annotations": annotations},
				"spec": map[string]any{
					"containers": []any{container},
				},
			},
		},
	}
	return json.Marshal(svc)
}

// envList drops blank pairs (the form ships fixed empty rows) and shapes the
// rest as Knative container env entries.
func envList(env []FnEnv) []any {
	out := make([]any, 0, len(env))
	for _, e := range env {
		if e.Name == "" {
			continue
		}
		out = append(out, map[string]any{"name": e.Name, "value": e.Value})
	}
	return out
}

func (k *Client) CreateFunctionService(ctx context.Context, ns, name string, opts FnOpts) error {
	body, err := BuildFunctionService(ns, name, opts)
	if err != nil {
		return err
	}
	return k.do(ctx, http.MethodPost, ksvcPath(ns), bytes.NewReader(body), nil)
}

// DeleteKnativeService removes a Knative Service by name from a project
// namespace — the one whose portal-tenant grant lets the portal delete it. The
// Functions page only offers Delete for project namespaces for exactly this
// reason (capstone ksvcs in `pipeline`, not a project, are shown read-only).
func (k *Client) DeleteKnativeService(ctx context.Context, ns, name string) error {
	if !ValidName(name) {
		return fmt.Errorf("invalid name %q", name)
	}
	// 404 → already gone: a double-delete or a stale tab is a no-op, not an error.
	if err := k.do(ctx, http.MethodDelete, ksvcPath(ns)+"/"+name, nil, nil); err != nil {
		if isNotFound(err) {
			return nil
		}
		return err
	}
	return nil
}

// GetKnativeService fetches one Knative Service (URL + conditions) for its
// detail page. 404 → nil (deleted, or a different project selected).
func (k *Client) GetKnativeService(ctx context.Context, ns, name string) (*KnativeService, error) {
	if !ValidName(ns) || !ValidName(name) {
		return nil, fmt.Errorf("invalid namespace/name")
	}
	var svc KnativeService
	if err := k.get(ctx, ksvcPath(ns)+"/"+name, &svc); err != nil {
		if isNotFound(err) {
			return nil, nil
		}
		return nil, err
	}
	return &svc, nil
}
