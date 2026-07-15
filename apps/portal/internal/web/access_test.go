package web

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"cloudbox.io/portal/internal/kube"
)

// fakeRuler satisfies selfRuler with a canned review — the payoff of the
// consumer-side interface: the Access page needs no live authorization API.
type fakeRuler kube.SelfRules

func (f fakeRuler) SelfRules(context.Context, string) (kube.SelfRules, error) {
	return kube.SelfRules(f), nil
}

func TestFetchAccessViaFake(t *testing.T) {
	fake := fakeRuler(kube.SelfRules{
		Namespace: "portal",
		ResourceRules: []kube.ResourceRule{
			{Verbs: []string{"get", "list", "watch"}, APIGroups: []string{""}, Resources: []string{"pods"}},
			{Verbs: []string{"get", "list"}, APIGroups: []string{"apps"}, Resources: []string{"deployments", "statefulsets"}},
		},
		Incomplete: false,
	})

	data, err := fetchAccess(t.Context(), fake, "portal")
	if err != nil {
		t.Fatal(err)
	}
	if data.Namespace != "portal" {
		t.Errorf("namespace = %q, want portal", data.Namespace)
	}
	if len(data.Rules) != 2 {
		t.Fatalf("rules = %d, want 2", len(data.Rules))
	}
	// The core group ("" on the wire) must render as the readable "core".
	if data.Rules[0].APIGroups != "core" {
		t.Errorf("core group rendered as %q, want core", data.Rules[0].APIGroups)
	}
	if data.Rules[0].Verbs != "get, list, watch" {
		t.Errorf("verbs = %q", data.Rules[0].Verbs)
	}
	if data.Rules[1].Resources != "deployments, statefulsets" {
		t.Errorf("resources = %q", data.Rules[1].Resources)
	}

	// The rendered table must show the verbs and resources.
	tmpl, err := ParseTemplates(&Server{})
	if err != nil {
		t.Fatalf("parsing templates: %v", err)
	}
	var buf bytes.Buffer
	if err := tmpl.ExecuteTemplate(&buf, "access", data); err != nil {
		t.Fatalf("rendering access: %v", err)
	}
	for _, want := range []string{"SelfSubjectRulesReview", "pods", "get, list, watch", "deployments, statefulsets", "namespace <code>portal</code>"} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("rendered access page missing %q", want)
		}
	}
}

// TestAccessAlwaysOpen pins the page's defining property: it has no Unlock
// predicate, so it must stay reachable even from a bare cluster (empty
// snapshot) — this is a meta/security page, not a gated capability.
func TestAccessAlwaysOpen(t *testing.T) {
	it, ok := findNavItem(navGroups(kube.Snapshot{}), "access")
	if !ok {
		t.Fatal("nav is missing the Access page")
	}
	if it.Locked {
		t.Error("Access has no Unlock predicate and must never lock")
	}
}
