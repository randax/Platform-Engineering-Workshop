package kube

import "testing"

// A Knative deployment scaled to zero (desired 0, ready 0) counts as ready:
// wanting zero and having zero is success.
func TestScaleToZeroCountsAsReady(t *testing.T) {
	w := workload{} // all-zero status = scaled to zero
	desired := max(w.Status.Replicas, w.Status.DesiredNumberScheduled)
	ready := max(w.Status.ReadyReplicas, w.Status.NumberReady)
	if ready < desired {
		t.Fatal("zero-desired workload must count as ready")
	}
}
