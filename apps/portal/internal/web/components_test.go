package web

import (
	"context"
	"strings"
	"testing"

	"cloudbox.io/portal/internal/kube"
)

func TestComponentRows(t *testing.T) {
	rows := componentRows(map[string]kube.NSHealth{
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

// fakeLister satisfies workloadLister with a canned map — the payoff of the
// consumer-side interface: component logic tests need no HTTP server.
type fakeLister map[string]kube.NSHealth

func (f fakeLister) NamespaceWorkloads(context.Context) (map[string]kube.NSHealth, error) {
	return f, nil
}

func TestFetchComponentsViaFake(t *testing.T) {
	data, err := fetchComponents(t.Context(), fakeLister{"gitea": {Ready: 1, Total: 1}})
	if err != nil {
		t.Fatal(err)
	}
	// Marketplace holds only catalog-backed components that aren't installed.
	// Catalog-less bootstrap rows (like gitea) stay in the health section
	// regardless of workload count — so they're never offered "one file away".
	catalogBacked := 0
	for _, c := range componentCatalog {
		if c.Catalog != "" {
			catalogBacked++
		}
	}
	if len(data.Marketplace) != catalogBacked {
		t.Errorf("marketplace = %d, want %d (catalog-backed)", len(data.Marketplace), catalogBacked)
	}
	if len(data.Running) != len(componentCatalog)-catalogBacked {
		t.Errorf("running = %d, want %d", len(data.Running), len(componentCatalog)-catalogBacked)
	}
	var gitea *componentRow
	for i := range data.Running {
		if data.Running[i].Namespace == "gitea" {
			gitea = &data.Running[i]
		}
	}
	if gitea == nil || gitea.Status != "Operational" {
		t.Errorf("gitea should be Operational in Running, got %+v", gitea)
	}
}

// TestComponentStatusLadder pins the one ladder both component surfaces use.
//
// The two middle rows are the module-10 regression. A Deployment surges, so a
// release that crashloops, gets OOM-killed at sandbox creation, or cannot pull
// leaves the OLD ReplicaSet serving every desired replica: Ready == Total is
// true and completely uninformative. Rehearsal 4 caught the Console printing
// "Operational · 3/3 workloads ready" over exactly that.
func TestComponentStatusLadder(t *testing.T) {
	cases := []struct {
		name          string
		h             kube.NSHealth
		status, class string
		unhealthy     bool
	}{
		{"empty namespace", kube.NSHealth{}, "Not installed", "off", false},
		{"all ready", kube.NSHealth{Ready: 3, Total: 3}, "Operational", "ok", false},
		{"partially ready", kube.NSHealth{Ready: 1, Total: 2}, "Degraded", "meh", true},
		{"nothing ready", kube.NSHealth{Ready: 0, Total: 1}, "Down", "bad", true},
		{
			// The captured state: demo, 3 workloads, all "ready", one Deployment
			// whose new pods have not come up for over two minutes.
			"full ready count over a stalled rollout",
			kube.NSHealth{Ready: 3, Total: 3, Updating: 1, Stalled: 1},
			"Degraded", "meh", true,
		},
		{
			// The same namespace ten seconds into a NORMAL deploy. A healthy
			// demo-web roll is in flight for ~14 s; saying "Degraded" and
			// offering a fault panel every time someone pushes is how a console
			// teaches people to ignore it.
			"full ready count during a healthy roll",
			kube.NSHealth{Ready: 3, Total: 3, Updating: 1},
			"Rolling out", "info", false,
		},
		{
			// A rollout in flight does not soften a component that is already
			// down on the plain ready count.
			"broken and rolling stays Degraded",
			kube.NSHealth{Ready: 1, Total: 3, Updating: 1},
			"Degraded", "meh", true,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			status, class := componentStatus(c.h)
			if status != c.status || class != c.class {
				t.Errorf("componentStatus = (%q, %q), want (%q, %q)", status, class, c.status, c.class)
			}
			if got := componentUnhealthy(c.h); got != c.unhealthy {
				t.Errorf("componentUnhealthy = %v, want %v", got, c.unhealthy)
			}
		})
	}
}

// The note is what stops "3/3 workloads ready" from being the whole story.
func TestRolloutNote(t *testing.T) {
	if note := rolloutNote(kube.NSHealth{Ready: 3, Total: 3}); note != "" {
		t.Errorf("a settled namespace must say nothing about rollouts, got %q", note)
	}
	stalled := rolloutNote(kube.NSHealth{Ready: 3, Total: 3, Updating: 1, Stalled: 1})
	if !strings.HasPrefix(stalled, "1 rollout has") || !strings.Contains(stalled, "still serving") {
		t.Errorf("stalled note must name the old version still serving, got %q", stalled)
	}
	if note := rolloutNote(kube.NSHealth{Ready: 3, Total: 3, Updating: 2}); note != "2 rollouts are in progress." {
		t.Errorf("in-flight note = %q", note)
	}
}

// The rows the list page renders must carry the new state through, and the
// marketplace hint must still only appear on components that aren't installed.
func TestComponentRowsCarryRolloutState(t *testing.T) {
	rows := componentRows(map[string]kube.NSHealth{
		"demo":  {Ready: 3, Total: 3, Updating: 1, Stalled: 1},
		"gitea": {Ready: 1, Total: 1, Updating: 1},
	})
	byNS := map[string]componentRow{}
	for _, r := range rows {
		byNS[r.Namespace] = r
	}
	if got := byNS["demo"]; got.Status != "Degraded" || got.Ready != 3 || got.Total != 3 {
		t.Errorf("demo row = %+v, want Degraded with its full 3/3 count intact", got)
	}
	if got := byNS["gitea"]; got.Status != "Rolling out" || got.Class != "info" {
		t.Errorf("gitea row = (%q, %q), want (Rolling out, info)", got.Status, got.Class)
	}
	if got := byNS["backstage"]; got.Hint != "enable gitops/catalog/backstage.yaml" {
		t.Errorf("uninstalled component lost its catalog hint: %q", got.Hint)
	}
}
