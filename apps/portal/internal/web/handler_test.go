package web

// Hermetic HTTP-handler tests — the layer the review (F1) called out as riskiest
// and untested (RBAC-gated writes, project-cookie scoping, fragment-vs-error
// responses), previously reachable only via the 20-minute rehearsal. The seam:
// kube.NewClient takes a URL, so a real *Server can be driven with its kube
// client pointed at an httptest stand-in for the API server — the full handler
// path (request → fetch → k8s call → render → response) runs with no cluster.

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"cloudbox.io/portal/internal/kube"
)

// newTestServer builds a *Server whose kube client talks to an httptest server
// standing in for the Kubernetes API. `k8s` handles that fake API — respond to
// the paths the handler under test will hit.
func newTestServer(t *testing.T, k8s http.HandlerFunc) *Server {
	t.Helper()
	api := httptest.NewServer(k8s)
	t.Cleanup(api.Close)
	kc, err := kube.NewClient(api.URL, "test-token")
	if err != nil {
		t.Fatalf("kube client: %v", err)
	}
	srv := &Server{Kube: kc, GrafanaURL: "http://grafana"}
	tmpl, err := ParseTemplates(srv)
	if err != nil {
		t.Fatalf("templates: %v", err)
	}
	srv.Tmpl = tmpl
	return srv
}

// A DELETE issues the right API call and answers with the refreshed list
// fragment carrying the delete flash — not an error page.
func TestHandleDeleteApplication(t *testing.T) {
	var deleted bool
	srv := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete && strings.HasSuffix(r.URL.Path, "/applications/web") {
			deleted = true
			w.WriteHeader(http.StatusOK)
			return
		}
		_, _ = w.Write([]byte(`{"items":[]}`)) // the re-list after delete
	})
	req := httptest.NewRequest(http.MethodDelete, "/applications/web", nil)
	req.SetPathValue("name", "web")
	rec := httptest.NewRecorder()

	handleDeleteApplication(srv, rec, req)

	if !deleted {
		t.Error("handler never issued a DELETE to the API")
	}
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}
	if body := rec.Body.String(); !strings.Contains(body, "Deleted web") {
		t.Errorf("expected the delete flash in the fragment, got:\n%s", body)
	}
}

// The list fragment renders a row that links into the detail view (the IA
// restructure) — full path through fetchApplications + the app-list template.
func TestHandleApplicationsList(t *testing.T) {
	srv := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"items":[{"metadata":{"name":"web","namespace":"demo"},` +
			`"spec":{"image":"ghcr.io/x/web:v1"},` +
			`"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}`))
	})
	req := httptest.NewRequest(http.MethodGet, "/applications/list", nil)
	rec := httptest.NewRecorder()

	handleApplicationsList(srv, rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, `href="/applications/web"`) {
		t.Errorf("list should render a row linking to /applications/web; got:\n%s", body)
	}
}

// A kube API error on the list path degrades to a flash inside the fragment —
// the polling attributes stay in the DOM so the table self-heals, rather than a
// full error page (the documented degrade-in-place contract).
func TestHandleApplicationsListDegradesOnError(t *testing.T) {
	srv := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	})
	req := httptest.NewRequest(http.MethodGet, "/applications/list", nil)
	rec := httptest.NewRecorder()

	handleApplicationsList(srv, rec, req)

	body := rec.Body.String()
	if !strings.Contains(body, "flash-error") {
		t.Errorf("expected an error flash in the fragment, got:\n%s", body)
	}
	if !strings.Contains(body, `hx-trigger="every 5s"`) {
		t.Errorf("polling attribute must survive the error so the table self-heals; got:\n%s", body)
	}
}

// activeProject reads the project cookie and scopes the API path to that
// namespace — so switching projects actually targets a different namespace.
func TestActiveProjectScopesNamespace(t *testing.T) {
	var gotPath string
	srv := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		_, _ = w.Write([]byte(`{"items":[]}`))
	})
	req := httptest.NewRequest(http.MethodGet, "/applications/list", nil)
	req.AddCookie(&http.Cookie{Name: "project", Value: "team-a"})
	handleApplicationsList(srv, httptest.NewRecorder(), req)

	if !strings.Contains(gotPath, "/namespaces/team-a/") {
		t.Errorf("API path = %q, want it scoped to the cookie's namespace team-a", gotPath)
	}
}
