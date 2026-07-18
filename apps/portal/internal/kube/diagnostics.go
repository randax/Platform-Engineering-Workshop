package kube

// Diagnostics — the "why is this unhealthy?" reads (DR-0005). The console
// already shows health (Ready/Total) and logs; this surfaces the CAUSE the way
// a platform engineer reads it by reflex: the failing pods' container states
// (ImagePullBackOff, CrashLoopBackOff, …) and the namespace's Warning events.
// Read-only — no new write plane; `events` is already in the portal-read grant.

import (
	"context"
	"sort"
)

// PodTrouble is one not-Ready pod and the container state that explains it —
// the reason/message a `kubectl describe pod` would show at the top.
type PodTrouble struct {
	Pod       string
	Container string
	Reason    string // Waiting/Terminated reason, e.g. ImagePullBackOff, CrashLoopBackOff
	Message   string
}

// Diagnostics is the read-only "why" for a namespace: the pods that aren't
// happy and the recent Warning events. Empty means "nothing obviously wrong"
// (the workloads may still be starting).
type Diagnostics struct {
	PodTroubles []PodTrouble
	Warnings    []Event
}

// Empty reports whether there is nothing to show (so the UI can hide the
// section entirely rather than render an empty panel).
func (d Diagnostics) Empty() bool { return len(d.PodTroubles) == 0 && len(d.Warnings) == 0 }

// podStatus is the slice of a core/v1 Pod we need to explain trouble: the phase
// and each container's current/last state with its reason+message.
type podStatus struct {
	Metadata ObjMeta `json:"metadata"`
	Status   struct {
		Phase             string `json:"phase"`
		ContainerStatuses []struct {
			Name  string `json:"name"`
			Ready bool   `json:"ready"`
			State struct {
				Waiting *struct {
					Reason  string `json:"reason"`
					Message string `json:"message"`
				} `json:"waiting"`
				Terminated *struct {
					Reason   string `json:"reason"`
					Message  string `json:"message"`
					ExitCode int    `json:"exitCode"`
				} `json:"terminated"`
			} `json:"state"`
		} `json:"containerStatuses"`
	} `json:"status"`
}

// NamespaceDiagnostics gathers the cause signals for one namespace: containers
// stuck Waiting or Terminated-with-error, plus recent Warning events. Both reads
// are best-effort — a partial answer (events but not pods, or vice versa) is
// more useful than an error, so a failed sub-read just yields fewer rows.
func (k *Client) NamespaceDiagnostics(ctx context.Context, ns string) (Diagnostics, error) {
	var d Diagnostics
	if !ValidName(ns) {
		return d, nil
	}

	var pods struct {
		Items []podStatus `json:"items"`
	}
	if err := k.get(ctx, "/api/v1/namespaces/"+ns+"/pods", &pods); err == nil {
		d.PodTroubles = podTroubles(pods.Items)
	}

	// Warning events for the namespace (newest first via ListEvents); cap the tail.
	if ev, err := k.ListEvents(ctx, "/api/v1/namespaces/"+ns+"/events", "type=Warning"); err == nil {
		if len(ev) > 10 {
			ev = ev[:10]
		}
		d.Warnings = ev
	}
	return d, nil
}

// podTroubles extracts the not-Ready containers whose state explains a fault:
// a non-benign Waiting reason, or a Terminated with a non-zero exit. Sorted
// (pod, container) for a stable UI. Pure over the parsed pod list, so it's
// testable without a live API.
func podTroubles(items []podStatus) []PodTrouble {
	var out []PodTrouble
	for _, p := range items {
		for _, c := range p.Status.ContainerStatuses {
			if c.Ready {
				continue
			}
			if w := c.State.Waiting; w != nil && !benignWaiting(w.Reason) {
				out = append(out, PodTrouble{Pod: p.Metadata.Name, Container: c.Name, Reason: w.Reason, Message: w.Message})
			} else if t := c.State.Terminated; t != nil && t.ExitCode != 0 {
				out = append(out, PodTrouble{Pod: p.Metadata.Name, Container: c.Name, Reason: t.Reason, Message: t.Message})
			}
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Pod != out[j].Pod {
			return out[i].Pod < out[j].Pod
		}
		return out[i].Container < out[j].Container
	})
	return out
}

// benignWaiting filters the Waiting reasons that are just "still starting", not
// a fault — showing them as trouble would cry wolf during a normal rollout.
func benignWaiting(reason string) bool {
	switch reason {
	case "", "ContainerCreating", "PodInitializing":
		return true
	default:
		return false
	}
}
