package web

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/logs"
	"cloudbox.io/portal/internal/metrics"
)

// sampleDetail is the mock view-model shared by the render test and the
// screenshot generator, so what we assert on is exactly what we screenshot.
func sampleDetail() componentDetailData {
	base := time.Date(2026, 7, 16, 9, 41, 7, 0, time.UTC)
	msgs := []string{
		`level=info msg="Reconciliation successful" cluster=app-db`,
		`level=info msg="backup completed" method=barmanObjectStore`,
		`level=warn msg="slow query" duration=812ms`,
		`level=info msg="checkpoint starting: time"`,
		`level=info msg="connection accepted" client=10.244.0.42`,
	}
	tail := make([]logs.Line, len(msgs))
	for i, m := range msgs {
		tail[i] = logs.Line{Time: base.Add(time.Duration(-i) * 11 * time.Second), Msg: m}
	}
	return componentDetailData{
		Name:        "CloudNativePG",
		Namespace:   "cnpg-system",
		Description: "Postgres operator behind the database self-service",
		Ready:       1, Total: 1, Status: "Operational", StatusClass: "ok",
		Telemetry:  true,
		CPUSpark:   metrics.Sparkline([]float64{0.01, 0.02, 0.015, 0.04, 0.03, 0.06, 0.045, 0.05, 0.07, 0.055, 0.048, 0.052}, "CPU usage"),
		MemSpark:   metrics.Sparkline([]float64{2.6e8, 2.9e8, 3.0e8, 3.05e8, 3.1e8, 3.2e8, 3.15e8, 3.27e8, 3.3e8, 3.28e8, 3.31e8, 3.27e8}, "memory working set"),
		CPUNow:     "0.052 cores",
		MemNow:     "312 MiB",
		Logs:       tail,
		MetricsURL: "#",
	}
}

func TestComponentDetailRender(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{GrafanaURL: "http://localhost:30030"})
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	// Telemetry present: sparklines + log tail render.
	var buf bytes.Buffer
	if err := tmpl.ExecuteTemplate(&buf, "component-detail", sampleDetail()); err != nil {
		t.Fatalf("render: %v", err)
	}
	html := buf.String()
	for _, want := range []string{"CloudNativePG", "Monitoring", "polyline", "0.052 cores", "312 MiB", "logtail", "slow query"} {
		if !strings.Contains(html, want) {
			t.Errorf("rendered detail missing %q", want)
		}
	}

	// No telemetry: the locked hint, and no monitor panel.
	locked := sampleDetail()
	locked.Telemetry = false
	buf.Reset()
	if err := tmpl.ExecuteTemplate(&buf, "component-detail", locked); err != nil {
		t.Fatalf("render locked: %v", err)
	}
	if h := buf.String(); !strings.Contains(h, "Observability isn't running") || strings.Contains(h, `class="monitor"`) {
		t.Errorf("locked state wrong: %s", h)
	}
}

// TestGenerateScreenshots writes standalone HTML (CSS inlined) for key pages to
// SCREENSHOTS_DIR so a headless browser can shoot them. Skipped in normal runs;
// run with:  SCREENSHOTS=1 SCREENSHOTS_DIR=/tmp/shots go test -run Screenshots ./internal/web/
func TestGenerateScreenshots(t *testing.T) {
	if os.Getenv("SCREENSHOTS") == "" {
		t.Skip("set SCREENSHOTS=1 to generate screenshot HTML")
	}
	dir := os.Getenv("SCREENSHOTS_DIR")
	if dir == "" {
		t.Fatal("SCREENSHOTS_DIR is required")
	}
	css, err := os.ReadFile("static/style.css")
	if err != nil {
		t.Fatalf("read css: %v", err)
	}
	tmpl, err := ParseTemplates(&Server{GrafanaURL: "http://localhost:30030"})
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	locked := sampleDetail()
	locked.Telemetry = false
	pages := []struct {
		file, tmpl string
		data       any
	}{
		{"component-detail-monitoring", "component-detail", sampleDetail()},
		{"component-detail-locked", "component-detail", locked},
		{"components", "components", sampleComponents()},
		{"services", "services", sampleServices()},
	}
	for _, p := range pages {
		var buf bytes.Buffer
		if err := tmpl.ExecuteTemplate(&buf, p.tmpl, p.data); err != nil {
			t.Fatalf("render %s: %v", p.file, err)
		}
		// Inline the stylesheet + drop the JS (unused for a static shot) so the
		// HTML is self-contained for the browser.
		out := strings.Replace(buf.String(),
			`<link rel="stylesheet" href="/static/style.css">`,
			"<style>\n"+string(css)+"\n</style>", 1)
		out = strings.NewReplacer(
			`<script src="/static/htmx.min.js"></script>`, "",
			`<script defer src="/static/egg.js"></script>`, "",
		).Replace(out)
		if err := os.WriteFile(filepath.Join(dir, p.file+".html"), []byte(out), 0o644); err != nil {
			t.Fatalf("write %s: %v", p.file, err)
		}
	}
}

// sampleComponents mocks the Components list so the screenshot shows the new
// per-component links alongside the marketplace framing.
func sampleComponents() componentsData {
	running := []componentRow{
		{component: component{Title: "ArgoCD", Namespace: "argocd", Description: "GitOps engine — syncs this very platform"}, Ready: 5, Total: 5, Status: "Operational", Class: "ok"},
		{component: component{Title: "CloudNativePG", Namespace: "cnpg-system", Description: "Postgres operator behind the database self-service"}, Ready: 1, Total: 1, Status: "Operational", Class: "ok"},
		{component: component{Title: "Observability", Namespace: "observability", Description: "VictoriaMetrics + VictoriaLogs + VictoriaTraces + Grafana, fed by the OTel Collector"}, Ready: 5, Total: 5, Status: "Operational", Class: "ok"},
		{component: component{Title: "Knative Serving", Namespace: "knative-serving", Description: "scale-to-zero serverless runtime"}, Ready: 2, Total: 3, Status: "Degraded", Class: "meh"},
	}
	shelf := []componentRow{
		{component: component{Title: "Backstage", Namespace: "backstage", Description: "the presenter's portal demo — heavyweight, enable last", Catalog: "backstage.yaml"}, Status: "Not installed", Class: "off", Hint: "enable gitops/catalog/backstage.yaml"},
	}
	return componentsData{Running: running, Marketplace: shelf}
}

// sampleServices mocks the Services page so the screenshot shows the request
// rate + p95 latency sparkline columns.
func sampleServices() []serviceRow {
	mk := func(name, url string, rate, lat []float64, latNow string) serviceRow {
		var r serviceRow
		r.Metadata = kube.ObjMeta{Name: name, Namespace: "pipeline"}
		r.KnativeService.Status.URL = url
		r.KnativeService.Status.Conditions = []kube.Condition{{Type: "Ready", Status: "True"}}
		r.Spark = metrics.Sparkline(rate, "request rate")
		r.Latency = metrics.Sparkline(lat, "p95 latency")
		r.LatencyNow = latNow
		r.Grafana = "#"
		return r
	}
	return []serviceRow{
		mk("uploader", "http://uploader.pipeline.127.0.0.1.sslip.io",
			[]float64{0, 1, 3, 2, 5, 4, 6, 5, 7, 6, 5, 6}, []float64{0.02, 0.03, 0.025, 0.04, 0.035, 0.05, 0.045, 0.06, 0.05, 0.055, 0.048, 0.052}, "52 ms"),
		mk("resizer", "http://resizer.pipeline.127.0.0.1.sslip.io",
			[]float64{0, 0, 1, 2, 1, 3, 2, 4, 3, 2, 3, 2}, []float64{0.1, 0.12, 0.11, 0.18, 0.15, 0.22, 0.19, 0.2, 0.17, 0.19, 0.16, 0.18}, "180 ms"),
	}
}
