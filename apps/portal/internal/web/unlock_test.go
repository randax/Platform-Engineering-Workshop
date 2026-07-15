package web

// The unlock mechanic: pages gate on live cluster state. These tests pin the
// two things that must never drift — which pages are gated (and on what), and
// which pages must always stay open regardless of the cluster.

import (
	"testing"

	"cloudbox.io/portal/internal/kube"
)

// findNavItem locates a page's sidebar entry by its active-key across groups.
func findNavItem(groups []navGroup, key string) (navItem, bool) {
	for _, g := range groups {
		for _, it := range g.Items {
			if it.Key == key {
				return it, true
			}
		}
	}
	return navItem{}, false
}

func TestNavUnlock(t *testing.T) {
	// The gated pages and the ArgoCD Application whose health unlocks each.
	gated := map[string]string{
		"services":  "knative-serving",  // module 06
		"databases": "crossplane",       // module 04
		"gallery":   "picture-pipeline", // module 09
	}
	// Pages with no Unlock predicate — these must be reachable from a bare
	// cluster, or a workshop attendee could never get started.
	alwaysOpen := []string{"overview", "workshop", "components", "billing", "activity"}

	// An empty snapshot: no Application is Healthy, so every gated page locks.
	empty := navGroups(kube.Snapshot{})
	for key := range gated {
		it, ok := findNavItem(empty, key)
		if !ok {
			t.Fatalf("nav is missing gated page %q", key)
		}
		if !it.Locked {
			t.Errorf("%q must be locked when no app is Healthy", key)
		}
	}
	for _, key := range alwaysOpen {
		it, ok := findNavItem(empty, key)
		if !ok {
			t.Fatalf("nav is missing always-open page %q", key)
		}
		if it.Locked {
			t.Errorf("%q has no Unlock predicate and must never lock", key)
		}
	}

	// A snapshot where each gating Application reports Healthy: every gated
	// page must now unlock.
	apps := map[string]kube.ArgoApp{}
	for _, app := range gated {
		apps[app] = fixtureApp(app, "Healthy")
	}
	healthy := navGroups(kube.Snapshot{Apps: apps})
	for key, app := range gated {
		it, ok := findNavItem(healthy, key)
		if !ok {
			t.Fatalf("nav is missing gated page %q", key)
		}
		if it.Locked {
			t.Errorf("%q must unlock once %q is Healthy", key, app)
		}
	}
}
