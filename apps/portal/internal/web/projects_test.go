package web

import (
	"net/http"
	"testing"

	"cloudbox.io/portal/internal/kube"
)

// activeProject picks the namespace the self-service pages act on from the
// `project` cookie, defaulting to the built-in project and rejecting anything
// that isn't a DNS label (so a crafted cookie can't be injected into an API path).
func TestActiveProject(t *testing.T) {
	s := &Server{}

	// No cookie → the default project.
	r, _ := http.NewRequest("GET", "/", nil)
	if got := s.activeProject(r); got != kube.XRNamespace {
		t.Errorf("no cookie: got %q, want default %q", got, kube.XRNamespace)
	}

	// A valid project cookie is honoured.
	r.AddCookie(&http.Cookie{Name: "project", Value: "team-a"})
	if got := s.activeProject(r); got != "team-a" {
		t.Errorf("cookie team-a: got %q", got)
	}

	// A non-DNS value falls back to the default — never trusted in a path.
	bad, _ := http.NewRequest("GET", "/", nil)
	bad.AddCookie(&http.Cookie{Name: "project", Value: "../evil"})
	if got := s.activeProject(bad); got != kube.XRNamespace {
		t.Errorf("invalid cookie must fall back to default, got %q", got)
	}
}
