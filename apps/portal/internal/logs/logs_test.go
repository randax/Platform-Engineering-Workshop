package logs

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestFilters(t *testing.T) {
	if got := NamespaceFilter("argocd"); got != `k8s.namespace.name:="argocd"` {
		t.Errorf("NamespaceFilter = %q", got)
	}
	if got := PodFilter("pipeline", "uploader-abc"); got != `k8s.namespace.name:="pipeline" k8s.pod.name:="uploader-abc"` {
		t.Errorf("PodFilter = %q", got)
	}
	// A value with a quote must not break out of the quoted string.
	if got := NamespaceFilter(`a"b`); !strings.HasPrefix(got, `k8s.namespace.name:="a\"b"`) {
		t.Errorf("unescaped value: %q", got)
	}
}

func TestTail(t *testing.T) {
	// A canned VictoriaLogs answer: JSON lines, newest first.
	vl := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/select/logsql/query" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		q := r.URL.Query().Get("query")
		for _, want := range []string{"_time:60m", `k8s.namespace.name:="argocd"`, "sort by (_time) desc", "limit 2"} {
			if !strings.Contains(q, want) {
				t.Errorf("query missing %q: %s", want, q)
			}
		}
		w.Write([]byte(
			`{"_time":"2026-07-15T21:00:02Z","_msg":"second","k8s.namespace.name":"argocd"}` + "\n" +
				`{"_time":"2026-07-15T21:00:01Z","_msg":"first","k8s.namespace.name":"argocd"}` + "\n"))
	}))
	defer vl.Close()

	c := &Client{base: vl.URL, http: vl.Client()}
	lines, err := c.Tail(t.Context(), NamespaceFilter("argocd"), time.Hour, 2)
	if err != nil {
		t.Fatalf("tail: %v", err)
	}
	if len(lines) != 2 || lines[0].Msg != "second" || lines[1].Msg != "first" {
		t.Fatalf("lines = %+v", lines)
	}
	if lines[0].Time.IsZero() {
		t.Error("timestamp not parsed")
	}

	// No matching logs must be nil, nil — never an error (empty-state).
	empty := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer empty.Close()
	c = &Client{base: empty.URL, http: empty.Client()}
	if lines, err := c.Tail(t.Context(), NamespaceFilter("nope"), time.Hour, 10); err != nil || lines != nil {
		t.Errorf("empty tail: got (%v, %v), want (nil, nil)", lines, err)
	}
}
