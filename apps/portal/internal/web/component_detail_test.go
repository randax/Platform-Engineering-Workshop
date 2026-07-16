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
	"cloudbox.io/portal/internal/nats"
	reg "cloudbox.io/portal/internal/registry"
	"cloudbox.io/portal/internal/store"
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

// TestPanelMonitoringRender guards the three per-component Monitoring panels
// (#56) added to the Builds / Streams / Buckets pages: each must render its
// monitor block with a sparkline when telemetry is present, and omit it
// entirely when it isn't. Cheap protection against a template typo that the
// SCREENSHOTS-gated generator wouldn't catch in a normal CI run.
func TestPanelMonitoringRender(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{GrafanaURL: "http://localhost:30030"})
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	cases := []struct {
		name, tmpl string
		on         any // telemetry present
		off        any // telemetry absent
	}{
		{"builds", "builds", sampleBuilds(), func() buildsData { d := sampleBuilds(); d.Telemetry = false; return d }()},
		{"streams", "streams", sampleStreams(), func() streamsData { d := sampleStreams(); d.Telemetry = false; return d }()},
		{"buckets", "buckets", sampleBuckets(), func() bucketsData { d := sampleBuckets(); d.Telemetry = false; return d }()},
	}
	for _, c := range cases {
		var on bytes.Buffer
		if err := tmpl.ExecuteTemplate(&on, c.tmpl, c.on); err != nil {
			t.Fatalf("render %s (telemetry on): %v", c.name, err)
		}
		if h := on.String(); !strings.Contains(h, "Monitoring") || !strings.Contains(h, "polyline") {
			t.Errorf("%s panel: telemetry-on render missing Monitoring/polyline", c.name)
		}
		var off bytes.Buffer
		if err := tmpl.ExecuteTemplate(&off, c.tmpl, c.off); err != nil {
			t.Fatalf("render %s (telemetry off): %v", c.name, err)
		}
		if h := off.String(); strings.Contains(h, `class="monitor"`) {
			t.Errorf("%s panel: telemetry-off render still shows the monitor block", c.name)
		}
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
		{"database-detail", "database-detail", sampleDatabaseDetail()},
		{"builds", "builds", sampleBuilds()},
		{"streams", "streams", sampleStreams()},
		{"buckets", "buckets", sampleBuckets()},
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
// rate + avg latency sparkline columns.
func sampleServices() []serviceRow {
	mk := func(name, url string, rate, lat []float64, latNow string) serviceRow {
		var r serviceRow
		r.Metadata = kube.ObjMeta{Name: name, Namespace: "pipeline"}
		r.KnativeService.Status.URL = url
		r.KnativeService.Status.Conditions = []kube.Condition{{Type: "Ready", Status: "True"}}
		r.Spark = metrics.Sparkline(rate, "request rate")
		r.Latency = metrics.Sparkline(lat, "avg latency")
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

// sampleBuilds mocks the Builds page so the screenshot shows the Argo +
// builds-namespace Monitoring panel above the workflow runs and registry.
func sampleBuilds() buildsData {
	mkWF := func(name, phase, started string) kube.Workflow {
		var w kube.Workflow
		w.Metadata = kube.ObjMeta{Name: name, Namespace: "builds"}
		w.Status.Phase = phase
		w.Status.StartedAt = started
		return w
	}
	return buildsData{
		Workflows: []kube.Workflow{
			mkWF("build-api-7f2c9", "Succeeded", "2026-07-16T09:38:02Z"),
			mkWF("build-web-3a1b8", "Running", "2026-07-16T09:41:15Z"),
		},
		Repos: []reg.Repo{
			{Name: "api", Tags: []string{"latest", "sha-7f2c9"}},
			{Name: "web", Tags: []string{"latest"}},
		},
		Telemetry: true,
		CPUSpark:  metrics.Sparkline([]float64{0.05, 0.2, 0.6, 0.9, 0.7, 0.3, 0.1, 0.4, 0.8, 0.5, 0.2, 0.1}, "CPU usage"),
		CPUNow:    "0.112 cores",
		MemSpark:  metrics.Sparkline([]float64{1.2e8, 1.4e8, 2.1e8, 2.6e8, 2.4e8, 1.9e8, 1.6e8, 2.0e8, 2.5e8, 2.2e8, 1.8e8, 1.7e8}, "memory working set"),
		MemNow:    "162 MiB",
	}
}

// sampleStreams mocks the Streams page so the screenshot shows the NATS
// exporter Monitoring panel above the JetStream table.
func sampleStreams() streamsData {
	return streamsData{
		Streams: []nats.Stream{
			{Name: "ORDERS", Messages: 1284, Bytes: 3 << 20, Consumers: 2},
			{Name: "EVENTS", Messages: 57, Bytes: 96 << 10, Consumers: 1},
		},
		Telemetry: true,
		MsgSpark:  metrics.Sparkline([]float64{200, 420, 610, 780, 900, 1020, 1140, 1200, 1240, 1260, 1280, 1341}, "JetStream messages"),
		MsgNow:    "1341",
		ConnSpark: metrics.Sparkline([]float64{3, 4, 4, 5, 6, 5, 6, 7, 6, 6, 5, 6}, "connections"),
		ConnNow:   "6",
		BytesNow:  "3.1 MiB",
	}
}

// sampleBuckets mocks the Buckets page so the screenshot shows the generic
// RustFS resource Monitoring panel above the bucket list.
func sampleBuckets() bucketsData {
	base := time.Date(2026, 7, 16, 9, 12, 0, 0, time.UTC)
	return bucketsData{
		Buckets: []store.BucketInfo{
			{Name: "uploads", Created: base},
			{Name: "thumbnails", Created: base.Add(90 * time.Second)},
		},
		Telemetry: true,
		CPUSpark:  metrics.Sparkline([]float64{0.01, 0.03, 0.02, 0.05, 0.04, 0.06, 0.05, 0.07, 0.06, 0.05, 0.04, 0.05}, "CPU usage"),
		CPUNow:    "0.048 cores",
		MemSpark:  metrics.Sparkline([]float64{8.0e7, 8.4e7, 9.0e7, 9.2e7, 9.6e7, 1.0e8, 9.8e7, 1.02e8, 1.0e8, 9.9e7, 1.0e8, 9.8e7}, "memory working set"),
		MemNow:    "94 MiB",
	}
}

// sampleDatabaseDetail mocks the database detail page so the screenshot shows
// the CNPG Monitoring panel (connections / transactions / size).
func sampleDatabaseDetail() dbDetailData {
	var d dbDetailData
	d.Name = "my-app"
	var wdb kube.WorkshopDB
	wdb.Metadata = kube.ObjMeta{Name: "my-app", Namespace: "demo"}
	wdb.Spec.Size = "small"
	wdb.Spec.StorageGB = 1
	wdb.Status.Conditions = []kube.Condition{{Type: "Ready", Status: "True", Reason: "Available", Message: "Composed and ready"}}
	d.DB = &wdb
	var cl kube.CNPGClusterDetail
	cl.Spec.Instances = 1
	cl.Spec.Storage.Size = "1Gi"
	cl.Status.Phase = "Cluster in healthy state"
	cl.Status.ReadyInstances = 1
	cl.Status.Conditions = []kube.Condition{{Type: "Ready", Status: "True", Reason: "ClusterIsReady", Message: "Cluster is Ready"}}
	d.Cluster = &cl
	d.ClusterName = "my-app-pg"
	d.Secret = "my-app-pg-app"
	d.Psql = "kubectl -n demo exec -it my-app-pg-1 -- psql -U app app"
	d.GrafanaURL = "#"
	d.Events = []kube.Event{{Type: "Normal", Reason: "Scheduled", Message: "Successfully assigned demo/my-app-pg-1"}}
	d.Telemetry = true
	d.ConnSpark = metrics.Sparkline([]float64{2, 3, 2, 4, 3, 5, 4, 4, 5, 4, 3, 4}, "connections")
	d.ConnNow = "4"
	d.CacheSpark = metrics.Sparkline([]float64{99.1, 99.3, 99.2, 99.5, 99.4, 99.6, 99.5, 99.7, 99.6, 99.5, 99.6, 99.7}, "cache hit ratio")
	d.CacheNow = "99.7%"
	d.SizeNow = "14 MiB"
	return d
}
