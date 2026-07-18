package registry

// Hermetic tests for the Zot catalog/tags decoding — feeds the Builds page, a
// raw net/http + New(url) client that was 0% covered, so a registry API-shape
// change was caught only by the weekly rehearsal (adversarial review F5).

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCatalog(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v2/_catalog":
			_, _ = w.Write([]byte(`{"repositories":["app-web","fn-hello"]}`))
		case "/v2/app-web/tags/list":
			_, _ = w.Write([]byte(`{"tags":["b7","b8"]}`))
		case "/v2/fn-hello/tags/list":
			_, _ = w.Write([]byte(`{"tags":["v1"]}`))
		default:
			t.Errorf("unexpected path %q", r.URL.Path)
		}
	}))
	defer srv.Close()

	repos, err := New(srv.URL).Catalog(context.Background())
	if err != nil {
		t.Fatalf("Catalog: %v", err)
	}
	if len(repos) != 2 {
		t.Fatalf("got %d repos, want 2", len(repos))
	}
	if repos[0].Name != "app-web" || len(repos[0].Tags) != 2 {
		t.Errorf("repos[0] = %+v, want app-web with 2 tags", repos[0])
	}
	if repos[1].Name != "fn-hello" || len(repos[1].Tags) != 1 || repos[1].Tags[0] != "v1" {
		t.Errorf("repos[1] = %+v, want fn-hello [v1]", repos[1])
	}
}

// A repo whose tags listing fails must still appear, just tag-less — tags are
// decoration and one failure can't sink the whole Builds page.
func TestCatalogTagFailureIsSoft(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v2/_catalog" {
			_, _ = w.Write([]byte(`{"repositories":["broken"]}`))
			return
		}
		w.WriteHeader(http.StatusInternalServerError) // tags fail
	}))
	defer srv.Close()

	repos, err := New(srv.URL).Catalog(context.Background())
	if err != nil {
		t.Fatalf("Catalog: %v", err)
	}
	if len(repos) != 1 || repos[0].Name != "broken" || len(repos[0].Tags) != 0 {
		t.Errorf("want one tag-less repo, got %+v", repos)
	}
}

func TestCatalogError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	if _, err := New(srv.URL).Catalog(context.Background()); err == nil {
		t.Error("expected an error when the catalog GET fails")
	}
}
