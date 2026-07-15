package web

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestTeapot(t *testing.T) {
	w := httptest.NewRecorder()
	Teapot(nil, w, httptest.NewRequest("GET", "/teapot", nil))
	if w.Code != http.StatusTeapot {
		t.Errorf("teapot status = %d, want 418", w.Code)
	}
	if body := w.Body.String(); body == "" || body[0:3] != "The" {
		t.Errorf("teapot body = %q", body)
	}
}

func TestNotFoundStatus(t *testing.T) {
	s := &Server{GrafanaURL: "http://localhost:30030"}
	tmpl, err := ParseTemplates(s)
	if err != nil {
		t.Fatal(err)
	}
	s.Tmpl = tmpl
	w := httptest.NewRecorder()
	NotFound(s, w, httptest.NewRequest("GET", "/nonsense", nil))
	if w.Code != http.StatusNotFound {
		t.Errorf("notfound status = %d, want 404", w.Code)
	}
	if !contains(w.Body.String(), "scaled to zero") {
		t.Error("notfound page missing the joke")
	}
}

func TestCloudHeaders(t *testing.T) {
	h := CloudHeaders(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/", nil))
	for k, want := range map[string]string{
		"X-Cloud-Provider": "you",
		"X-Egress-Fee":     "0.00",
		"X-Region":         "eu-laptop-1",
	} {
		if got := w.Header().Get(k); got != want {
			t.Errorf("%s = %q, want %q", k, got, want)
		}
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
