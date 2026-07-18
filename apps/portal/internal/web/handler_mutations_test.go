package web

// Hermetic tests for the mutating handlers — the create/resize/provision paths
// the review named as riskiest and rehearsal-only. Reuses newTestServer
// (handler_test.go): a real *Server whose kube client talks to an httptest
// stand-in for the API server, so the full path runs with no cluster.

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func formReq(method, target string, form url.Values) *http.Request {
	req := httptest.NewRequest(method, target, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return req
}

// Creating an app from a prebuilt image POSTs the Application XR and answers with
// the refreshed list fragment carrying the "Deploying" flash.
func TestHandleCreateApplication(t *testing.T) {
	var posted bool
	srv := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/applications") {
			posted = true
			w.WriteHeader(http.StatusCreated)
			return
		}
		_, _ = w.Write([]byte(`{"items":[]}`)) // the re-list after create
	})
	req := formReq(http.MethodPost, "/applications", url.Values{
		"name": {"myapp"}, "source": {"image"}, "image": {"ghcr.io/x/y:v1"},
		"min": {"0"}, "max": {"3"},
	})
	rec := httptest.NewRecorder()

	handleCreateApplication(srv, rec, req)

	if !posted {
		t.Error("handler never POSTed the Application XR")
	}
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "Deploying myapp") {
		t.Errorf("expected the deploy flash, got:\n%s", rec.Body.String())
	}
}

// Resize patches the DB and drives a clean HX-Redirect (the server-driven
// mutate-then-navigate pattern the review preferred), not a timed reload.
func TestHandleResizeDatabaseRedirects(t *testing.T) {
	var patched bool
	srv := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPatch {
			patched = true
		}
		w.WriteHeader(http.StatusOK)
	})
	req := formReq(http.MethodPost, "/databases/my-db/resize", url.Values{"size": {"medium"}})
	req.SetPathValue("name", "my-db")
	rec := httptest.NewRecorder()

	handleResizeDatabase(srv, rec, req)

	if !patched {
		t.Error("resize did not issue a PATCH")
	}
	if got := rec.Header().Get("HX-Redirect"); got != "/databases/my-db" {
		t.Errorf("HX-Redirect = %q, want /databases/my-db", got)
	}
}

// On a kube error, resize degrades to an in-place flash — no redirect, so the
// user stays put and sees why.
func TestHandleResizeDatabaseErrorFlash(t *testing.T) {
	srv := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	})
	req := formReq(http.MethodPost, "/databases/my-db/resize", url.Values{"size": {"medium"}})
	req.SetPathValue("name", "my-db")
	rec := httptest.NewRecorder()

	handleResizeDatabase(srv, rec, req)

	if rec.Header().Get("HX-Redirect") != "" {
		t.Error("must not redirect on error")
	}
	if !strings.Contains(rec.Body.String(), "Resize failed") {
		t.Errorf("expected an error flash, got:\n%s", rec.Body.String())
	}
}

// Creating a project provisions BOTH the namespace and the tenant RoleBinding
// (two POSTs), sets the active-project cookie, and refreshes.
func TestHandleCreateProject(t *testing.T) {
	var posts int
	srv := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			posts++
		}
		w.WriteHeader(http.StatusCreated)
	})
	req := formReq(http.MethodPost, "/projects", url.Values{"name": {"team-a"}})
	req.Header.Set("HX-Request", "true")
	rec := httptest.NewRecorder()

	HandleCreateProject(srv, rec, req)

	if posts < 2 {
		t.Errorf("expected a Namespace + RoleBinding POST, got %d POSTs", posts)
	}
	if rec.Header().Get("HX-Refresh") != "true" {
		t.Error("expected HX-Refresh after create")
	}
	if !strings.Contains(rec.Header().Get("Set-Cookie"), "project=team-a") {
		t.Errorf("active-project cookie not set to the new project: %q", rec.Header().Get("Set-Cookie"))
	}
}
