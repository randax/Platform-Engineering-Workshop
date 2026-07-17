package web

import (
	"bytes"
	"net/http"
	"strings"
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

// The project-bar fragment renders the switcher: the active project, a switch
// link + delete per non-default project, no delete on the default, and the
// New-project affordance.
func TestProjectBarRender(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{})
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	var buf bytes.Buffer
	data := projectBarData{Active: "team-a", Default: "demo", Projects: []string{"demo", "team-a"}}
	if err := tmpl.ExecuteTemplate(&buf, "project-bar", data); err != nil {
		t.Fatalf("render project-bar: %v", err)
	}
	out := buf.String()
	for _, want := range []string{
		`href="/project?set=demo"`,     // switch to the default
		`href="/project?set=team-a"`,   // switch to team-a
		`hx-delete="/projects/team-a"`, // delete a non-default project
		`hx-post="/projects"`,          // the create form
		`for="proj-modal"`,             // the New-project trigger
	} {
		if !strings.Contains(out, want) {
			t.Errorf("project-bar missing %q", want)
		}
	}
	// The default project must NOT be deletable.
	if strings.Contains(out, `hx-delete="/projects/demo"`) {
		t.Error("the default project must not offer delete")
	}
}
