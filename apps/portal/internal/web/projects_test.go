package web

import (
	"bytes"
	"net/http"
	"net/http/httptest"
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
	r.AddCookie(&http.Cookie{Name: "project", Value: "teama"})
	if got := s.activeProject(r); got != "teama" {
		t.Errorf("cookie teama: got %q", got)
	}

	// A HYPHENATED cookie is not: it is a DNS label, so the old ValidName check
	// let it through, but a project namespace with a '-' can compose the same
	// Knative host as another (name, namespace) pair. Falls back to the default.
	legacy, _ := http.NewRequest("GET", "/", nil)
	legacy.AddCookie(&http.Cookie{Name: "project", Value: "team-a"})
	if got := s.activeProject(legacy); got != kube.XRNamespace {
		t.Errorf("hyphenated cookie must fall back to the default, got %q", got)
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
	// team-a here is deliberately a LEGACY project: the bar still lists and
	// offers to delete one, it just cannot be switched into or deployed to.
	data := projectBarData{Active: "teama", Default: "demo", Projects: projectEntries([]string{"demo", "team-a"})}
	if err := tmpl.ExecuteTemplate(&buf, "project-bar", data); err != nil {
		t.Fatalf("render project-bar: %v", err)
	}
	out := buf.String()
	for _, want := range []string{
		`href="/project?set=demo"`,     // switch to the default
		`hx-delete="/projects/team-a"`, // delete a non-default project
		`hx-post="/projects"`,          // the create form
		`for="proj-modal"`,             // the New-project trigger
		`(read-only)`,                  // ...and team-a says why it is not a link
	} {
		if !strings.Contains(out, want) {
			t.Errorf("project-bar missing %q", want)
		}
	}
	// A legacy project must NOT get a switch link: HandleProjectSwitch answers
	// 400 for it, so the link's only outcome is an error page.
	if strings.Contains(out, `href="/project?set=team-a"`) {
		t.Error("a hyphenated project must not be rendered as a switch link")
	}
	// The default project must NOT be deletable.
	if strings.Contains(out, `hx-delete="/projects/demo"`) {
		t.Error("the default project must not offer delete")
	}
}

// Deleting the project the cookie NAMES must reset the cookie — including a
// legacy hyphenated one, which activeProject normalises to the default before
// returning. Comparing against that normalised value meant the cookie survived
// the deletion of the very namespace it named: reads fell back to `demo` while
// mutableProject kept refusing every write, so the console stayed read-only for
// the rest of the session with no project left to switch away from.
func TestHandleDeleteProjectResetsTheCookie(t *testing.T) {
	for _, tc := range []struct {
		name    string
		cookie  string
		deleted string
		want    bool // must the response reset the cookie to the default?
	}{
		{"the active project", "teama", "teama", true},
		{"a legacy hyphenated project", "team-a", "team-a", true},
		{"some other project", "teama", "teamb", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/api/v1/namespaces/") {
					_, _ = w.Write([]byte(`{"metadata":{"labels":{"` + kube.ProjectLabel + `":"true"}}}`))
					return
				}
				_, _ = w.Write([]byte(`{"items":[]}`))
			})
			req := httptest.NewRequest(http.MethodDelete, "/projects/"+tc.deleted, nil)
			req.SetPathValue("name", tc.deleted)
			req.AddCookie(&http.Cookie{Name: "project", Value: tc.cookie})
			rec := httptest.NewRecorder()

			HandleDeleteProject(srv, rec, req)

			sc := rec.Header().Get("Set-Cookie")
			reset := strings.Contains(sc, "project="+kube.XRNamespace)
			if reset != tc.want {
				t.Errorf("cookie %q, deleted %q: Set-Cookie = %q, reset-to-default = %v, want %v",
					tc.cookie, tc.deleted, sc, reset, tc.want)
			}
		})
	}
}
