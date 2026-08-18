package kube

// Cluster-wide workload health, grouped by namespace. "One namespace per
// component" is a repo convention, so this is all the Components page needs.

import (
	"context"
	"time"
)

// StallAfter is how long a Deployment may make NO rollout progress before the
// console stops calling it "Rolling out" and calls it stalled — the console's
// own, much shorter progress deadline.
//
// Kubernetes has this concept already (spec.progressDeadlineSeconds, default
// 600) but 10 minutes is longer than an entire workshop module, so waiting for
// the cluster's own verdict is useless here. The window is picked from measured
// behaviour on this stack (2026-08-18, Talos v1.13.x / k8s v1.36.2):
//
//   - healthy demo-web roll: in flight for 14 s end to end, and the Progressing
//     condition's lastUpdateTime ADVANCED every ~6 s while it rolled
//     (14:12:42 → :48 → :54). A healthy rollout never goes quiet for long,
//     whatever its total length.
//   - module 10 scenarios 1 and 2: lastUpdateTime FROZEN at the moment the new
//     ReplicaSet appeared, and it stays frozen.
//   - slowest healthy rollout on record: Backstage, 57 s to Ready
//     (docs/HAZARDS.md, rehearsal 2).
//
// So the signal is a gap in progress, not elapsed time, and 120 s is ~2× the
// slowest healthy rollout we have ever measured and 20× the observed gap
// between progress updates — while still being 1/5 of the cluster's own
// deadline. Erring long is deliberate: a console that cries wolf on a normal
// deploy is the failure mode this repo keeps fixing.
const StallAfter = 120 * time.Second

// nsHealth counts the workloads in one namespace and how many of them are
// fully ready. A workload scaled to zero (Knative between requests!) counts
// as ready — wanting zero and having zero is success, not failure.
type NSHealth struct {
	Ready, Total int

	// Rollout state, Deployments only (see workload.rollout). Updating counts
	// the ones with a rollout in flight; Stalled counts the subset that has
	// stopped making progress. Both exist because Ready/Total CANNOT see a bad
	// release: a Deployment surges the new pods alongside the old ReplicaSet,
	// so while the new pods crash, get OOM-killed or never pull, the old ones
	// keep serving and readyReplicas stays at its full desired count. That is
	// exactly what module 10's scenarios do, and it is why "3/3 workloads
	// ready · Operational" was being printed over a broken release.
	Updating, Stalled int
}

// wcond is a Deployment status condition. The shared Condition type carries no
// timestamps; the rollout check needs lastUpdateTime, which is the field the
// Deployment controller itself uses to enforce progressDeadlineSeconds.
type wcond struct {
	Type           string `json:"type"`
	Status         string `json:"status"`
	Reason         string `json:"reason"`
	LastUpdateTime string `json:"lastUpdateTime"`
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
		Replicas int  `json:"replicas"`
		Paused   bool `json:"paused"` // a paused Deployment is stopped on purpose
	} `json:"spec"`
	Status struct {
		ReadyReplicas          int `json:"readyReplicas"`          // deploy + sts
		DesiredNumberScheduled int `json:"desiredNumberScheduled"` // daemonset
		NumberReady            int `json:"numberReady"`            // daemonset

		// Rollout fields (deployment). unavailableReplicas counts pods the
		// rollout still owes across ALL its ReplicaSets, so it stays > 0 while
		// a surged new pod fails — the one number readyReplicas can't mask.
		ObservedGeneration  int64   `json:"observedGeneration"`
		UpdatedReplicas     int     `json:"updatedReplicas"`
		UnavailableReplicas int     `json:"unavailableReplicas"`
		Conditions          []wcond `json:"conditions"`
	} `json:"status"`
}

// rollout classifies a Deployment's rollout. Kept as a pure function of the
// object plus "now" so every state below is testable without a cluster.
type rollout int

const (
	rolloutSettled  rollout = iota // nothing in flight
	rolloutUpdating                // a release is on its way, and moving
	rolloutStalled                 // a release is on its way and has stopped moving
)

// progressing returns the Deployment's Progressing condition, or nil.
func (w workload) progressing() *wcond {
	for i := range w.Status.Conditions {
		if w.Status.Conditions[i].Type == "Progressing" {
			return &w.Status.Conditions[i]
		}
	}
	return nil
}

// rollout answers "is this Deployment mid-release, and if so is the release
// still moving?" — deliberately in that order, because the honest answer to a
// release in flight is "rolling out", not "degraded". Only a release that has
// gone QUIET for StallAfter (or that Kubernetes itself has given up on) counts
// as stalled.
//
// Deployments only. A StatefulSet or DaemonSet rolling update takes its old pod
// down before bringing the new one up, so a bad image there already drops
// readyReplicas below desired and is caught by the plain Ready < Total count.
// Deployments are the only one of the three that can surge, which is the whole
// reason this function has to exist.
func (w workload) rollout(now time.Time) rollout {
	// Paused is deliberate, and a Deployment scaled to zero has nothing to roll.
	if w.Spec.Paused || w.Spec.Replicas == 0 {
		return rolloutSettled
	}
	inFlight := w.Status.ObservedGeneration < w.Metadata.Generation ||
		w.Status.UpdatedReplicas < w.Spec.Replicas ||
		w.Status.UnavailableReplicas > 0
	if !inFlight {
		return rolloutSettled
	}
	// The controller hasn't seen this spec yet, so its conditions still describe
	// the PREVIOUS revision — their timestamps say nothing about this rollout.
	if w.Status.ObservedGeneration < w.Metadata.Generation {
		return rolloutUpdating
	}
	p := w.progressing()
	if p == nil {
		return rolloutUpdating
	}
	switch p.Reason {
	case "ProgressDeadlineExceeded":
		// Kubernetes' own verdict; no need to second-guess it.
		return rolloutStalled
	case "NewReplicaSetAvailable", "DeploymentPaused":
		// The controller considers the rollout finished (or deliberately
		// stopped) while the replica counts still lag — a stale-status blink,
		// not a stall.
		return rolloutUpdating
	}
	last, err := time.Parse(time.RFC3339, p.LastUpdateTime)
	if err != nil {
		return rolloutUpdating // unreadable timestamp: never accuse on a guess
	}
	if now.Sub(last) > StallAfter {
		return rolloutStalled
	}
	return rolloutUpdating
}

func (k *Client) NamespaceWorkloads(ctx context.Context) (map[string]NSHealth, error) {
	health := map[string]NSHealth{}
	now := time.Now()
	for _, src := range []struct {
		path string
		// rollouts: only Deployments can hide a bad release behind a still-
		// serving old ReplicaSet (see workload.rollout).
		rollouts bool
	}{
		{"/apis/apps/v1/deployments", true},
		{"/apis/apps/v1/statefulsets", false},
		{"/apis/apps/v1/daemonsets", false},
	} {
		var list struct {
			Items []workload `json:"items"`
		}
		if err := k.get(ctx, src.path, &list); err != nil {
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
			if src.rollouts {
				switch w.rollout(now) {
				case rolloutStalled:
					h.Stalled++
					h.Updating++ // stalled is a subset of in-flight
				case rolloutUpdating:
					h.Updating++
				}
			}
			health[w.Metadata.Namespace] = h
		}
	}
	return health, nil
}
