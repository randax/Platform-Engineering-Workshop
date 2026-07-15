package web

// The Builds page: pins the unlock gate (Argo Workflows Healthy) and proves
// the fragment renders workflow runs and the registry catalog from fakes — no
// live Argo or Zot in the loop — including the degrade-in-place behaviour when
// one source fails.

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"cloudbox.io/portal/internal/kube"
	reg "cloudbox.io/portal/internal/registry" // aliased: the web package already has a `registry` var (the page registry)
)

// fakeWorkflows and fakeCatalog are in-memory implementations of the two
// consumer interfaces the page reads, so its rendering is testable without
// standing up Argo Workflows or Zot.
type fakeWorkflows struct {
	wfs []kube.Workflow
	err error
}

func (f fakeWorkflows) ListArgoWorkflows(context.Context) ([]kube.Workflow, error) {
	return f.wfs, f.err
}

type fakeCatalog struct {
	repos []reg.Repo
	err   error
}

func (f fakeCatalog) Catalog(context.Context) ([]reg.Repo, error) {
	return f.repos, f.err
}

// TestBuildsUnlock pins the gate: locked from a bare cluster, unlocked the
// moment argo-workflows reports Healthy (mirrors unlock_test.go's approach).
func TestBuildsUnlock(t *testing.T) {
	if it, ok := findNavItem(navGroups(kube.Snapshot{}), "builds"); !ok {
		t.Fatal("nav is missing the builds page")
	} else if !it.Locked {
		t.Error("builds must be locked when argo-workflows is not Healthy")
	}

	apps := map[string]kube.ArgoApp{"argo-workflows": fixtureApp("argo-workflows", "Healthy")}
	if it, ok := findNavItem(navGroups(kube.Snapshot{Apps: apps}), "builds"); !ok {
		t.Fatal("nav is missing the builds page")
	} else if it.Locked {
		t.Error("builds must unlock once argo-workflows is Healthy")
	}
}

// TestBuildsRender feeds fakes through the same helper the handler uses, then
// renders the fragment and asserts the run row (name, phase badge, humanized
// duration) and the registry catalog (repo + tags) all land in the markup.
func TestBuildsRender(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{})
	if err != nil {
		t.Fatalf("parsing templates: %v", err)
	}

	wf := kube.Workflow{}
	wf.Metadata.Name = "build-cloudbox-abc12"
	wf.Status.Phase = "Succeeded"
	wf.Status.StartedAt = "2026-07-15T10:00:00Z"
	wf.Status.FinishedAt = "2026-07-15T10:01:30Z" // 90s later

	wl := fakeWorkflows{wfs: []kube.Workflow{wf}}
	cl := fakeCatalog{repos: []reg.Repo{{Name: "cloudbox/uploader", Tags: []string{"v1", "latest"}}}}

	data := gatherBuilds(context.Background(), wl, cl)

	var buf bytes.Buffer
	if err := tmpl.ExecuteTemplate(&buf, "builds-runs", data); err != nil {
		t.Fatalf("rendering builds-runs: %v", err)
	}
	out := buf.String()

	for _, want := range []string{
		"build-cloudbox-abc12",  // the run name
		`badge ok`,              // Succeeded → green badge
		"Succeeded",             // the phase label
		"1m30s",                 // 90s duration, humanized
		"cloudbox/uploader",     // a registry repository
		"latest",                // one of its tags
		`hx-trigger="every 5s"`, // the fragment polls itself
	} {
		if !strings.Contains(out, want) {
			t.Errorf("rendered fragment missing %q", want)
		}
	}
}

// TestBuildsDegrade proves the two sources fail independently: Argo errors but
// Zot answers, so the page shows the workflow error flash AND still renders the
// catalog section — degrade in place, never a blank page.
func TestBuildsDegrade(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{})
	if err != nil {
		t.Fatalf("parsing templates: %v", err)
	}

	wl := fakeWorkflows{err: errors.New("connection refused")}
	cl := fakeCatalog{repos: []reg.Repo{{Name: "cloudbox/resizer"}}}

	data := gatherBuilds(context.Background(), wl, cl)

	var buf bytes.Buffer
	if err := tmpl.ExecuteTemplate(&buf, "builds-runs", data); err != nil {
		t.Fatalf("rendering builds-runs: %v", err)
	}
	out := buf.String()

	if !strings.Contains(out, "flash-error") {
		t.Error("expected a workflow error flash when the Argo API fails")
	}
	if !strings.Contains(out, "connection refused") {
		t.Error("the workflow error text should surface in the flash")
	}
	if !strings.Contains(out, "cloudbox/resizer") {
		t.Error("the registry section must still render when workflows fail")
	}
	if !strings.Contains(out, "— no tags") {
		t.Error("a tag-less repo should render the empty-tags state")
	}
}
