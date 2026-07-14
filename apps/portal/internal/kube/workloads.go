package kube

// Cluster-wide workload health, grouped by namespace. "One namespace per
// component" is a repo convention, so this is all the Components page needs.

import "context"

// nsHealth counts the workloads in one namespace and how many of them are
// fully ready. A workload scaled to zero (Knative between requests!) counts
// as ready — wanting zero and having zero is success, not failure.
type NSHealth struct {
	Ready, Total int
}

// workload is the tiny slice of Deployment/StatefulSet/DaemonSet status we
// need. The three kinds spell "desired" and "ready" differently; the unused
// pair decodes as zero, so max() picks the right one either way.
type workload struct {
	Metadata ObjMeta `json:"metadata"`
	Spec     struct {
		// desired replicas for deploy + sts. status.replicas is the CURRENT
		// pod count, which can transiently equal readyReplicas mid-scale-up
		// and report a namespace healthy before the scale-up finishes.
		Replicas int `json:"replicas"`
	} `json:"spec"`
	Status struct {
		ReadyReplicas          int `json:"readyReplicas"`          // deploy + sts
		DesiredNumberScheduled int `json:"desiredNumberScheduled"` // daemonset
		NumberReady            int `json:"numberReady"`            // daemonset
	} `json:"status"`
}

func (k *Client) NamespaceWorkloads(ctx context.Context) (map[string]NSHealth, error) {
	health := map[string]NSHealth{}
	for _, path := range []string{
		"/apis/apps/v1/deployments",
		"/apis/apps/v1/statefulsets",
		"/apis/apps/v1/daemonsets",
	} {
		var list struct {
			Items []workload `json:"items"`
		}
		if err := k.get(ctx, path, &list); err != nil {
			return nil, err
		}
		for _, w := range list.Items {
			desired := max(w.Spec.Replicas, w.Status.DesiredNumberScheduled)
			ready := max(w.Status.ReadyReplicas, w.Status.NumberReady)
			h := health[w.Metadata.Namespace]
			h.Total++
			if ready >= desired {
				h.Ready++
			}
			health[w.Metadata.Namespace] = h
		}
	}
	return health, nil
}
