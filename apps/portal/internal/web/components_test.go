package web

import (
	"context"
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
