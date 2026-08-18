package kube

import (
	"encoding/json"
	"testing"
	"time"
)

// A Knative deployment scaled to zero (desired 0, ready 0) counts as ready:
// wanting zero and having zero is success.
func TestScaleToZeroCountsAsReady(t *testing.T) {
	w := workload{} // all-zero spec/status = scaled to zero
	desired := max(w.Spec.Replicas, w.Status.DesiredNumberScheduled)
	ready := max(w.Status.ReadyReplicas, w.Status.NumberReady)
	if ready < desired {
		t.Fatal("zero-desired workload must count as ready")
	}
}

// now is the fixed "current time" the rollout table is judged against; the
// captured timestamps below are expressed relative to it.
var rolloutNow = time.Date(2026, 8, 18, 14, 5, 0, 0, time.UTC)

func ago(d time.Duration) string { return rolloutNow.Add(-d).Format(time.RFC3339) }

// TestRolloutState is the module-10 regression: a Deployment whose new pods are
// failing while its OLD ReplicaSet still serves reports a full ready count, so
// the rollout fields are the only place the truth lives.
//
// The first three rows are transcribed from the live cluster on 2026-08-18
// (Talos v1.13.x / k8s v1.36.2) — the healthy baseline, then module 10 scenario
// 1 (CrashLoopBackOff) and scenario 2 (the new pod never leaves
// ContainerCreating because its sandbox is OOM-killed). Scenarios 1 and 2
// produce byte-identical Deployment status; the pods differ, the rollout does
// not, which is exactly why the fix reads the rollout and not the pods.
func TestRolloutState(t *testing.T) {
	// captured builds the demo-web Deployment as the API server reported it in
	// each state: 2 desired, the old ReplicaSet's 2 pods still Ready, one surged
	// new pod that never became available.
	captured := func(progReason, progStatus, lastUpdate string) workload {
		var w workload
		w.Metadata.Namespace, w.Metadata.Generation = "demo", 2
		w.Spec.Replicas = 2
		w.Status.ObservedGeneration = 2
		w.Status.ReadyReplicas = 2
		w.Status.UpdatedReplicas = 1
		w.Status.UnavailableReplicas = 1
		w.Status.Conditions = []wcond{
			{Type: "Available", Status: "True", Reason: "MinimumReplicasAvailable", LastUpdateTime: ago(17 * time.Minute)},
			{Type: "Progressing", Status: progStatus, Reason: progReason, LastUpdateTime: lastUpdate},
		}
		return w
	}
	// settled is the same Deployment with nothing in flight.
	settled := func() workload {
		w := captured("NewReplicaSetAvailable", "True", ago(17*time.Minute))
		w.Status.UpdatedReplicas = 2
		w.Status.UnavailableReplicas = 0
		return w
	}

	cases := []struct {
		name string
		w    workload
		want rollout
	}{
		{"healthy steady state", settled(), rolloutSettled},
		{
			// Captured 10 s after ./inject.sh 1: deploy 2/2 ready, replicas 3,
			// updated 1, unavailable 1, Progressing=True/ReplicaSetUpdated frozen
			// at the rollout's start. Identical for scenario 2.
			"module 10 fault, 10 s in — moving, not yet stalled",
			captured("ReplicaSetUpdated", "True", ago(10*time.Second)),
			rolloutUpdating,
		},
		{
			// Same object 3 minutes later: lastUpdateTime has not moved, because
			// the rollout hasn't. Kubernetes itself waits 600 s to say so.
			"module 10 fault, 3 min in — stalled",
			captured("ReplicaSetUpdated", "True", ago(3*time.Minute)),
			rolloutStalled,
		},
		{
			// A healthy demo-web roll measured on the same cluster stayed in
			// flight for 14 s and its lastUpdateTime advanced every ~6 s. The
			// console must not call that anything but "rolling out".
			"healthy roll mid-flight",
			captured("ReplicaSetUpdated", "True", ago(6*time.Second)),
			rolloutUpdating,
		},
		{
			"kubernetes' own verdict is taken immediately",
			captured("ProgressDeadlineExceeded", "False", ago(10*time.Second)),
			rolloutStalled,
		},
		{
			// The controller says the rollout finished while the replica counts
			// still lag by a beat — a stale-status blink, not a stall, however
			// old the condition is.
			"completed rollout with lagging counts",
			captured("NewReplicaSetAvailable", "True", ago(30*time.Minute)),
			rolloutUpdating,
		},
		{
			"paused on purpose",
			func() workload {
				w := captured("DeploymentPaused", "Unknown", ago(1*time.Hour))
				w.Spec.Paused = true
				return w
			}(),
			rolloutSettled,
		},
		{
			"scaled to zero has nothing to roll",
			func() workload {
				w := captured("ReplicaSetUpdated", "True", ago(1*time.Hour))
				w.Spec.Replicas = 0
				return w
			}(),
			rolloutSettled,
		},
		{
			// The spec was pushed a moment ago and the controller hasn't looked
			// yet, so its conditions still describe the PREVIOUS revision. Their
			// timestamps must not be read as this rollout going quiet.
			"controller has not observed the new spec",
			func() workload {
				w := captured("ReplicaSetUpdated", "True", ago(1*time.Hour))
				w.Status.ObservedGeneration = 1
				return w
			}(),
			rolloutUpdating,
		},
		{
			"no Progressing condition at all",
			func() workload { w := captured("", "", ""); w.Status.Conditions = w.Status.Conditions[:1]; return w }(),
			rolloutUpdating,
		},
		{
			"unreadable timestamp is never an accusation",
			captured("ReplicaSetUpdated", "True", "not-a-timestamp"),
			rolloutUpdating,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := c.w.rollout(rolloutNow); got != c.want {
				t.Errorf("rollout = %v, want %v", got, c.want)
			}
		})
	}
}

// The stall window has to clear the slowest healthy rollout by a wide margin —
// Backstage takes 57 s to Ready on the rehearsal machine (docs/HAZARDS.md) —
// while staying well under Kubernetes' own 600 s progressDeadlineSeconds, which
// is longer than the module that needs this signal.
func TestStallAfterHasHeadroom(t *testing.T) {
	if StallAfter < 90*time.Second {
		t.Errorf("StallAfter = %s: too tight, a slow but healthy rollout would be called degraded", StallAfter)
	}
	if StallAfter >= 600*time.Second {
		t.Errorf("StallAfter = %s: no earlier than the cluster's own verdict, so it buys nothing", StallAfter)
	}
}

// The rollout fields must survive the JSON the API server actually sends —
// including unavailableReplicas being ABSENT (it is omitempty) when zero.
func TestWorkloadDecodesRolloutFields(t *testing.T) {
	const body = `{"metadata":{"name":"demo-web","namespace":"demo","generation":2},
	  "spec":{"replicas":2},
	  "status":{"observedGeneration":2,"replicas":3,"readyReplicas":2,"availableReplicas":2,
	    "updatedReplicas":1,"unavailableReplicas":1,
	    "conditions":[{"type":"Progressing","status":"True","reason":"ReplicaSetUpdated",
	      "lastUpdateTime":"2026-08-18T14:03:49Z","lastTransitionTime":"2026-08-18T14:03:49Z",
	      "message":"ReplicaSet \"demo-web-69dfd9d57c\" is progressing."}]}}`
	var w workload
	if err := json.Unmarshal([]byte(body), &w); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if w.Metadata.Generation != 2 || w.Status.ObservedGeneration != 2 {
		t.Errorf("generation %d / observed %d, want 2/2", w.Metadata.Generation, w.Status.ObservedGeneration)
	}
	if w.Status.UpdatedReplicas != 1 || w.Status.UnavailableReplicas != 1 {
		t.Errorf("updated %d / unavailable %d, want 1/1", w.Status.UpdatedReplicas, w.Status.UnavailableReplicas)
	}
	p := w.progressing()
	if p == nil || p.LastUpdateTime != "2026-08-18T14:03:49Z" {
		t.Fatalf("Progressing condition not decoded: %+v", p)
	}
	// The ready count that started all this: it is FULL while the release burns.
	if w.Status.ReadyReplicas < w.Spec.Replicas {
		t.Fatal("fixture is wrong: the point is that readyReplicas looks complete")
	}
	if w.rollout(time.Date(2026, 8, 18, 14, 10, 0, 0, time.UTC)) != rolloutStalled {
		t.Error("a release that has not moved for 6 minutes must read as stalled")
	}

	// Same object with unavailableReplicas omitted entirely and the counts level.
	var ok workload
	if err := json.Unmarshal([]byte(`{"metadata":{"generation":1},"spec":{"replicas":2},
	  "status":{"observedGeneration":1,"readyReplicas":2,"updatedReplicas":2,
	    "conditions":[{"type":"Progressing","status":"True","reason":"NewReplicaSetAvailable",
	      "lastUpdateTime":"2026-08-18T13:48:04Z"}]}}`), &ok); err != nil {
		t.Fatalf("decode healthy: %v", err)
	}
	if got := ok.rollout(time.Date(2026, 8, 18, 14, 10, 0, 0, time.UTC)); got != rolloutSettled {
		t.Errorf("healthy deployment rollout = %v, want settled", got)
	}
}
