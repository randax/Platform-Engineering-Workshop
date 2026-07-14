package metrics

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSparkline(t *testing.T) {
	if got := Sparkline(nil); got != "" {
		t.Errorf("nil input must render nothing (empty-state dash), got %q", got)
	}
	if got := Sparkline([]float64{1}); got != "" {
		t.Errorf("single point can't make a line, got %q", got)
	}
	svg := string(Sparkline([]float64{0, 2, 1, 3}))
	for _, want := range []string{"<svg", "polyline", "aria-label"} {
		if !strings.Contains(svg, want) {
			t.Errorf("sparkline missing %q in %s", want, svg)
		}
	}
	// A flat all-zero series (idle service) must still render a line.
	if flat := string(Sparkline([]float64{0, 0, 0})); !strings.Contains(flat, "polyline") {
		t.Errorf("flat series must render: %s", flat)
	}
}

func TestQueryRange(t *testing.T) {
	// A canned Prometheus answer: one series, three samples.
	prom := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/query_range" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		if q := r.URL.Query().Get("query"); !strings.Contains(q, "cloudbox-uploader") {
			t.Errorf("query missing job: %s", q)
		}
		w.Write([]byte(`{"status":"success","data":{"result":[{"values":[[1,"0.5"],[2,"1.0"],[3,"2.5"]]}]}}`))
	}))
	defer prom.Close()

	p := &Client{base: prom.URL, http: prom.Client()}
	vals, err := p.QueryRange(t.Context(), RequestRateQuery("cloudbox-uploader"))
	if err != nil {
		t.Fatalf("queryRange: %v", err)
	}
	if len(vals) != 3 || vals[2] != 2.5 {
		t.Errorf("vals = %v", vals)
	}

	// No series (metrics not flowing yet) must be nil, nil — never an error.
	empty := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"status":"success","data":{"result":[]}}`))
	}))
	defer empty.Close()
	p = &Client{base: empty.URL, http: empty.Client()}
	if vals, err := p.QueryRange(t.Context(), "whatever"); err != nil || vals != nil {
		t.Errorf("empty result: got (%v, %v), want (nil, nil)", vals, err)
	}
}
