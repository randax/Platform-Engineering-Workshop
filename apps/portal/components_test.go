package main

import "testing"

func TestComponentRows(t *testing.T) {
	rows := componentRows(map[string]nsHealth{
		"kube-system": {Ready: 3, Total: 3}, // everything ready
		"pipeline":    {Ready: 1, Total: 2}, // partially ready
		"rustfs":      {Ready: 0, Total: 1}, // present but dead
		// cnpg-system absent entirely → not installed
	})

	byNS := map[string]componentRow{}
	for _, r := range rows {
		byNS[r.Namespace] = r
	}

	cases := map[string]struct {
		status, class, hint string
	}{
		"kube-system": {"Operational", "ok", ""},
		"pipeline":    {"Degraded", "meh", ""},
		"rustfs":      {"Down", "bad", ""},
		"cnpg-system": {"Not installed", "off", "enable gitops/catalog/cnpg-operator.yaml"},
	}
	for ns, want := range cases {
		got := byNS[ns]
		if got.Status != want.status || got.Class != want.class || got.Hint != want.hint {
			t.Errorf("%s: got (%s, %s, %q), want (%s, %s, %q)",
				ns, got.Status, got.Class, got.Hint, want.status, want.class, want.hint)
		}
	}

	// Core components installed by bootstrap must not point at the catalog.
	if byNS["kube-system"].Catalog != "" {
		t.Errorf("kube-system should have no catalog hint")
	}
	if len(rows) != len(componentCatalog) {
		t.Errorf("expected one row per component, got %d/%d", len(rows), len(componentCatalog))
	}
}

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
