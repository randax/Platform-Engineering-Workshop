package kube

// Hermetic tests for the hand-rolled HTTP layer (do/get/patchMerge/isNotFound) —
// the code most prone to silent breakage (a wrong path, a bumped apiVersion, the
// merge-patch content type do() deliberately can't send) and, before this, guarded
// only by the 20-minute rehearsal. An httptest.Server + a Client pointed at it
// exercises the real request/response path with no cluster (adversarial review F2).

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// testClient spins an httptest server and a Client aimed at it. The handler runs
// per request, so a test can capture what the client actually sent.
func testClient(t *testing.T, h http.HandlerFunc) *Client {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return &Client{baseURL: srv.URL, token: "test-token", client: srv.Client()}
}

func TestClientGet(t *testing.T) {
	var gotAuth, gotMethod, gotPath, gotAccept string
	k := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotMethod, gotPath = r.Header.Get("Authorization"), r.Method, r.URL.Path
		gotAccept = r.Header.Get("Accept")
		_, _ = w.Write([]byte(`{"metadata":{"name":"gitea"}}`))
	})
	var out struct {
		Metadata ObjMeta `json:"metadata"`
	}
	if err := k.get(context.Background(), "/api/v1/namespaces/gitea", &out); err != nil {
		t.Fatalf("get: %v", err)
	}
	if out.Metadata.Name != "gitea" {
		t.Errorf("decoded name = %q, want gitea", out.Metadata.Name)
	}
	if gotMethod != http.MethodGet {
		t.Errorf("method = %q, want GET", gotMethod)
	}
	if gotPath != "/api/v1/namespaces/gitea" {
		t.Errorf("path = %q", gotPath)
	}
	if gotAuth != "Bearer test-token" {
		t.Errorf("Authorization = %q, want the bearer token", gotAuth)
	}
	_ = gotAccept
}

func TestClientDoSendsJSONBody(t *testing.T) {
	var gotCT, gotBody, gotMethod string
	k := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		gotCT, gotMethod = r.Header.Get("Content-Type"), r.Method
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.WriteHeader(http.StatusCreated)
	})
	if err := k.do(context.Background(), http.MethodPost, "/apis/x/y", strings.NewReader(`{"a":1}`), nil); err != nil {
		t.Fatalf("do: %v", err)
	}
	if gotMethod != http.MethodPost {
		t.Errorf("method = %q, want POST", gotMethod)
	}
	if gotCT != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", gotCT)
	}
	if gotBody != `{"a":1}` {
		t.Errorf("body = %q", gotBody)
	}
}

// The status is preserved so isNotFound can tell "normal absence" (404) apart
// from a real failure (403/500) — the distinction the whole apiError type exists for.
func TestClientErrorStatus(t *testing.T) {
	for _, tc := range []struct {
		code     int
		notFound bool
	}{
		{http.StatusForbidden, false},
		{http.StatusNotFound, true},
		{http.StatusInternalServerError, false},
	} {
		code := tc.code
		k := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(code)
			_, _ = w.Write([]byte(`{"message":"boom"}`))
		})
		err := k.get(context.Background(), "/x", nil)
		if err == nil {
			t.Errorf("status %d: expected an error", code)
			continue
		}
		if isNotFound(err) != tc.notFound {
			t.Errorf("status %d: isNotFound = %v, want %v", code, isNotFound(err), tc.notFound)
		}
		var ae *apiError
		if !errors.As(err, &ae) || ae.Status != code {
			t.Errorf("status %d: want *apiError with that status, got %v", code, err)
		}
	}
}

// patchMerge MUST send application/merge-patch+json — do()'s hardcoded
// application/json is rejected by the API server for PATCH, which is the entire
// reason patchMerge exists. A regression here silently breaks every Resize/Redeploy.
func TestClientPatchMerge(t *testing.T) {
	var gotCT, gotMethod, gotBody string
	k := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		gotCT, gotMethod = r.Header.Get("Content-Type"), r.Method
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
	})
	if err := k.patchMerge(context.Background(), "/apis/x/y/z", strings.NewReader(`{"spec":{"image":"v2"}}`)); err != nil {
		t.Fatalf("patchMerge: %v", err)
	}
	if gotMethod != http.MethodPatch {
		t.Errorf("method = %q, want PATCH", gotMethod)
	}
	if gotCT != "application/merge-patch+json" {
		t.Errorf("Content-Type = %q, want application/merge-patch+json", gotCT)
	}
	if gotBody != `{"spec":{"image":"v2"}}` {
		t.Errorf("body = %q", gotBody)
	}
}

// A representative public method end-to-end: GetApplication maps a 404 to
// (nil, nil) — "no such app" is a normal answer a detail page relies on, not an error.
func TestGetApplicationNotFound(t *testing.T) {
	k := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	app, err := k.GetApplication(context.Background(), "demo", "missing")
	if err != nil {
		t.Fatalf("GetApplication on 404: unexpected error %v", err)
	}
	if app != nil {
		t.Errorf("GetApplication on 404: got %+v, want nil", app)
	}
}
