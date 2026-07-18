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

// Deleting a function targets the namespace from the URL path, NOT the project
// cookie. The Functions list is cluster-wide, so a function viewed under project
// team-a must be deleted from team-a even when the cookie says demo — the bug
// this guards against silently deleted demo/<name> instead. Assert the k8s
// DELETE landed on the team-a path despite the cookie.
func TestHandleDeleteFunctionUsesPathNamespaceNotCookie(t *testing.T) {
	var deletePath string
	srv := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			deletePath = r.URL.Path
			w.WriteHeader(http.StatusOK)
			return
		}
		_, _ = w.Write([]byte(`{"items":[]}`)) // the re-list after delete
	})
	req := httptest.NewRequest(http.MethodDelete, "/services/team-a/fn-x", nil)
	req.SetPathValue("namespace", "team-a")
	req.SetPathValue("name", "fn-x")
	req.AddCookie(&http.Cookie{Name: "project", Value: "demo"}) // the cookie must NOT win
	rec := httptest.NewRecorder()

	handleDeleteFunction(srv, rec, req)

	if deletePath == "" {
		t.Fatal("handler never issued a DELETE to the API")
	}
	if !strings.Contains(deletePath, "/namespaces/team-a/") {
		t.Errorf("DELETE path = %q, want it scoped to the URL namespace team-a, not the cookie's demo", deletePath)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}
	if body := rec.Body.String(); !strings.Contains(body, "Deleted fn-x") {
		t.Errorf("expected the delete flash in the fragment, got:\n%s", body)
	}
}

// A failed delete must still be visible: the detail page redirects on any 2xx,
// so the handler signals failure with the X-Delete-Failed header (the template's
// hx-on guard reads it to suppress the silent redirect). Success sets no header.
func TestHandleDeleteFunctionSignalsFailureHeader(t *testing.T) {
	srv := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			http.Error(w, `{"message":"forbidden"}`, http.StatusForbidden)
			return
		}
		_, _ = w.Write([]byte(`{"items":[]}`)) // the re-list after delete
	})
	req := httptest.NewRequest(http.MethodDelete, "/services/demo/fn-x", nil)
	req.SetPathValue("namespace", "demo")
	req.SetPathValue("name", "fn-x")
	rec := httptest.NewRecorder()

	handleDeleteFunction(srv, rec, req)

	if rec.Header().Get("X-Delete-Failed") != "1" {
		t.Errorf("expected X-Delete-Failed=1 on a failed delete, got %q", rec.Header().Get("X-Delete-Failed"))
	}
	if body := rec.Body.String(); !strings.Contains(body, "Delete failed") {
		t.Errorf("expected the error flash in the fragment, got:\n%s", body)
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
