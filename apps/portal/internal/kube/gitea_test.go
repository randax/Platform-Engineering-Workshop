package kube

import (
	"context"
	"strings"
	"testing"
)

// ScaffoldRepo must reject bad input and refuse to run unconfigured BEFORE it
// ever reaches out to Gitea — the validation is the anti-SSRF/typo guard.
func TestScaffoldRepoValidation(t *testing.T) {
	k := &Client{}
	ctx := context.Background()

	// No credentials → the feature is off; report it, don't call out.
	t.Setenv("GITEA_USER", "")
	if _, err := k.ScaffoldRepo(ctx, DefaultTemplate, "app"); err == nil ||
		!strings.Contains(err.Error(), "configured") {
		t.Fatalf("unconfigured ScaffoldRepo: want 'not configured' error, got %v", err)
	}

	// With creds set, bad names/templates are still rejected up front.
	t.Setenv("GITEA_USER", "gitea_admin")
	t.Setenv("GITEA_PASSWORD", "x")
	for _, name := range []string{"", "Bad_Name", "no/slash", ".."} {
		if _, err := k.ScaffoldRepo(ctx, DefaultTemplate, name); err == nil {
			t.Errorf("ScaffoldRepo(name=%q): expected rejection", name)
		}
	}
	for _, tmpl := range []string{"", "noslash", "a/../b", "cloudbox/"} {
		if _, err := k.ScaffoldRepo(ctx, tmpl, "app"); err == nil {
			t.Errorf("ScaffoldRepo(template=%q): expected rejection", tmpl)
		}
	}
}

func TestGiteaConfigured(t *testing.T) {
	t.Setenv("GITEA_USER", "")
	if GiteaConfigured() {
		t.Error("GiteaConfigured() = true with GITEA_USER unset")
	}
	t.Setenv("GITEA_USER", "gitea_admin")
	if !GiteaConfigured() {
		t.Error("GiteaConfigured() = false with GITEA_USER set")
	}
}
