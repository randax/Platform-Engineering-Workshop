package web

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"cloudbox.io/portal/internal/kagent"
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
	tmpl, err := ParseTemplates(&Server{GrafanaURL: "http://grafana.cloudbox.k8s.test"})
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

// TestComponentDetailCaseFile pins the Case file mount on the component detail
// (the demo namespace's workloads) — the seam that gives lab faults a path into
// the Console. Same shared affordance as the Application detail: the live mount
// when the agent is available, the locked hint (no mount) when it isn't.
func TestComponentDetailCaseFile(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{GrafanaURL: "http://grafana.cloudbox.k8s.test"})
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	base := sampleDetail()
	base.Name, base.Namespace = "Demo workloads", "demo"
	base.Status, base.StatusClass = "Degraded", "meh"
	base.ShowDiag = true

	// Available: the shared investigation mount, keyed on the demo namespace, with
	// a DNS-valid resource name and the follow-up input.
	avail := base
	avail.CaseFile = caseFile{Show: true, Available: true, Kind: "Component", Namespace: "demo", Name: "demo"}
	var on bytes.Buffer
	if err := tmpl.ExecuteTemplate(&on, "component-detail", avail); err != nil {
		t.Fatalf("render available: %v", err)
	}
	h := on.String()
	// data-kind="Component" keeps the session distinct from an Application named
	// like this namespace.
	for _, want := range []string{"Case file", `id="case-file"`, `data-namespace="demo"`,
		`data-name="demo"`, `data-kind="Component"`, "Open investigation", `id="cf-followup"`} {
		if !strings.Contains(h, want) {
			t.Errorf("component-detail Case file missing %q", want)
		}
	}

	// Absent: locked affordance naming kagent, and no mount to reach the backend.
	locked := base
	locked.CaseFile = caseFile{Show: true, Available: false, Kind: "Component", Namespace: "demo", Name: "demo"}
	var off bytes.Buffer
	if err := tmpl.ExecuteTemplate(&off, "component-detail", locked); err != nil {
		t.Fatalf("render locked: %v", err)
	}
	if l := off.String(); !strings.Contains(l, "kagent") || strings.Contains(l, `id="case-file"`) {
		t.Errorf("locked component-detail Case file wrong:\n%s", l)
	}
}

// TestPanelMonitoringRender guards the three per-component Monitoring panels
// (#56) added to the Builds / Streams / Buckets pages: each must render its
// monitor block with a sparkline when telemetry is present, and omit it
// entirely when it isn't. Cheap protection against a template typo that the
// SCREENSHOTS-gated generator wouldn't catch in a normal CI run.
func TestPanelMonitoringRender(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{GrafanaURL: "http://grafana.cloudbox.k8s.test"})
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
	tmpl, err := ParseTemplates(&Server{GrafanaURL: "http://grafana.cloudbox.k8s.test"})
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
		{"applications", "applications", sampleApplications()},
		{"application-detail", "application-detail", sampleAppDetail()},
		{"function-detail", "function-detail", sampleFnDetail()},
		{"services", "services", functionsData{Rows: sampleServices(), Samples: fnSamples}},
		{"database-detail", "database-detail", sampleDatabaseDetail()},
		{"builds", "builds", sampleBuilds()},
		{"streams", "streams", sampleStreams()},
		{"buckets", "buckets", sampleBuckets()},
	}
	// The project bar is htmx-loaded at runtime; for a static shot, render the
	// fragment and inline it into the placeholder so every page shows the selector.
	var barBuf bytes.Buffer
	if err := tmpl.ExecuteTemplate(&barBuf, "project-bar", projectBarData{
		Active: "demo", Default: "demo", Projects: []string{"demo", "team-a"},
	}); err != nil {
		t.Fatalf("render project-bar: %v", err)
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
		out = strings.Replace(out,
			`<div id="project-bar" hx-get="/project/bar" hx-trigger="load"></div>`,
			`<div id="project-bar">`+barBuf.String()+`</div>`, 1)
		out = strings.NewReplacer(
			`<script src="/static/htmx.min.js"></script>`, "",
			`<script defer src="/static/egg.js"></script>`, "",
		).Replace(out)
		if err := os.WriteFile(filepath.Join(dir, p.file+".html"), []byte(out), 0o644); err != nil {
			t.Fatalf("write %s: %v", p.file, err)
		}
	}
}

// sampleApplications mocks the Applications page: one Ready app (with its URL)
// composed from the golden-path XR, and one still composing.
func sampleApplications() applicationsData {
	mk := func(name, image string, min, max int, ready bool) appRow {
		var a kube.Application
		a.Metadata = kube.ObjMeta{Name: name, Namespace: "demo"}
		a.Spec.Image = image
		a.Spec.Replicas.Min, a.Spec.Replicas.Max = min, max
		a.Spec.Database, a.Spec.Bucket = true, true
		if ready {
			a.Status.Conditions = []kube.Condition{{Type: "Ready", Status: "True", Reason: "Available"}}
		} else {
			a.Status.Conditions = []kube.Condition{{Type: "Ready", Status: "False", Reason: "Creating"}}
		}
		row := appRow{Application: a}
		if ready {
			row.URL = "http://" + name + "-demo.kn.cloudbox.k8s.test"
		}
		return row
	}
	// The source-built app carries a repo image + offers Redeploy; the other is
	// a prebuilt image. This is the healthy "hero" shot — the diagnostics state
	// gets its own sample (sampleApplicationsUnhealthy) so this one stays clean.
	src := mk("web", "localhost:30500/app-web:b7", 0, 3, true)
	src.SourceBuilt = true
	return applicationsData{Apps: []appRow{
		src,
		mk("api", "ghcr.io/acme/api:v2", 1, 5, false),
	}, ScaffoldEnabled: true}
}

// sampleAppDetail is the Application detail page in its most instructive state:
// a source-built app stuck on an unpullable image, showing the composed-resource
// cross-links AND the DR-0005 diagnostics (the cause a describe would show).
func sampleAppDetail() appDetailData {
	return appDetailData{
		Name: "api", Namespace: "demo", Found: true,
		Readiness:   kube.Readiness{Label: "Creating", Class: "meh"},
		URL:         "http://api-demo.kn.cloudbox.k8s.test",
		SourceBuilt: true,
		Repo:        "http://gitea-http.gitea.svc.cluster.local:3000/cloudbox/api.git",
		Branch:      "main",
		Composed: []composedRef{
			{Kind: "Workload", Name: "api", Note: "Knative Service — scales to zero; serves the URL above"},
			{Kind: "Database", Name: "api", Href: "/databases/api", Note: "Postgres, injected as DATABASE_URL"},
			{Kind: "Bucket", Name: "api-data", Href: "/buckets/api-data", Note: "S3 bucket, injected as S3_*"},
		},
		Why:      "cannot resolve resources: composed Deployment is not Available",
		ShowDiag: true,
		Diag: kube.Diagnostics{PodTroubles: []kube.PodTrouble{{
			Pod: "api-00001-deployment-6c9f-8t2wq", Container: "user-container",
			Reason: "ImagePullBackOff", Message: `Back-off pulling image "ghcr.io/acme/api:v2"`,
		}}},
		Telemetry:  true,
		ReqSpark:   metrics.Sparkline([]float64{0, 1, 2, 1, 3, 2}, "request rate"),
		LatSpark:   metrics.Sparkline([]float64{40, 55, 48, 60}, "avg latency"),
		LatNow:     "60 ms",
		MetricsURL: "#",
	}
}

// sampleFnDetail is the Function detail page with BOTH gated branches live
// (ShowDiag + Telemetry) so the render test exercises them — a stuck revision
// showing its diagnostics plus the monitoring panel.
func sampleFnDetail() fnDetailData {
	return fnDetailData{
		Name: "fn-hello", Namespace: "demo", Found: true,
		Readiness: kube.Readiness{Label: "RevisionFailed", Class: "meh"},
		URL:       "http://fn-hello-demo.kn.cloudbox.k8s.test",
		Deletable: true,
		Why:       `Revision "fn-hello-00001" failed: unable to fetch image`,
		ShowDiag:  true,
		Diag: kube.Diagnostics{PodTroubles: []kube.PodTrouble{{
			Pod: "fn-hello-00001-deployment-7c9f-2kx8m", Container: "user-container",
			Reason: "ImagePullBackOff", Message: `Back-off pulling image "localhost:30500/fn-hello:b7"`,
		}}},
		Telemetry: true,
		ReqSpark:  metrics.Sparkline([]float64{0, 1, 2, 1, 3, 2}, "request rate"),
		LatSpark:  metrics.Sparkline([]float64{40, 55, 48, 60}, "avg latency"),
		LatNow:    "60 ms",
		Scale:     "idle · 0 pods",
		TracesURL: "#",
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

// sampleServices mocks the Functions page rows so the screenshot shows the
// request-rate + avg-latency sparklines, scale-from-zero, and — for the
// demo-namespace function the console built — the Delete action.
func sampleServices() []serviceRow {
	mk := func(name, ns, url string, rate, lat []float64, latNow, scale string) serviceRow {
		var r serviceRow
		r.Metadata = kube.ObjMeta{Name: name, Namespace: ns}
		r.KnativeService.Status.URL = url
		r.KnativeService.Status.Conditions = []kube.Condition{{Type: "Ready", Status: "True"}}
		r.Spark = metrics.Sparkline(rate, "request rate")
		r.Latency = metrics.Sparkline(lat, "avg latency")
		r.LatencyNow = latNow
		r.Scale = scale
		r.Grafana = "#"
		r.Deletable = ns == "demo" // a project namespace → the console can delete it
		return r
	}
	return []serviceRow{
		mk("uploader", "pipeline", "http://uploader-pipeline.kn.cloudbox.k8s.test",
			[]float64{0, 1, 3, 2, 5, 4, 6, 5, 7, 6, 5, 6}, []float64{0.02, 0.03, 0.025, 0.04, 0.035, 0.05, 0.045, 0.06, 0.05, 0.055, 0.048, 0.052}, "52 ms", "2 running"),
		mk("resizer", "pipeline", "http://resizer-pipeline.kn.cloudbox.k8s.test",
			[]float64{0, 0, 1, 2, 1, 3, 2, 4, 3, 2, 3, 2}, []float64{0.1, 0.12, 0.11, 0.18, 0.15, 0.22, 0.19, 0.2, 0.17, 0.19, 0.16, 0.18}, "180 ms", "idle · 0 pods"),
		mk("fn-hello-site", "demo", "http://fn-hello-site-demo.kn.cloudbox.k8s.test",
			[]float64{0, 0, 0, 1, 0, 0, 2, 1, 0, 0, 1, 0}, []float64{0.01, 0.02, 0.015, 0.03, 0.02, 0.04, 0.03, 0.05, 0.03, 0.02, 0.04, 0.03}, "31 ms", "idle · 0 pods"),
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
			{Name: "images", Created: base},
			{Name: "thumbnails", Created: base.Add(90 * time.Second)},
		},
		// A selected bucket so the shot shows the upload form + per-object delete.
		Objects: objectsData{
			Bucket: "images",
			Objects: []objectRow{
				{ObjectInfo: store.ObjectInfo{Key: "originals/1-cat.png", Size: 250880, LastModified: base}, DownloadURL: "#"},
				{ObjectInfo: store.ObjectInfo{Key: "originals/2-dog.png", Size: 189440, LastModified: base.Add(2 * time.Minute)}, DownloadURL: "#"},
			},
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

// demoAPI stands in for the API server with the demo namespace exactly as it
// was captured on 2026-08-18 during module 10 scenario 1: three "ready"
// workloads, one of which is a Deployment whose surged new pod is in
// CrashLoopBackOff while its old ReplicaSet still serves both replicas.
//
//	$ kubectl -n demo get deploy demo-web
//	NAME       READY   UP-TO-DATE   AVAILABLE
//	demo-web   2/2     1            2
//	$ kubectl -n demo get pods -l app=demo-web
//	demo-web-69dfd9d57c-zm6v2   0/1   CrashLoopBackOff   4
//	demo-web-86c89df498-4k42z   1/1   Running            0
//	demo-web-86c89df498-xbxtm   1/1   Running            0
//
// progressedAt is when the Progressing condition last moved; the Console judges
// the rollout stalled once that stops advancing (kube.StallAfter).
func demoAPI(t *testing.T, progressedAt time.Time) http.HandlerFunc {
	t.Helper()
	deployments := fmt.Sprintf(`{"items":[
	  {"metadata":{"name":"demo-web","namespace":"demo","generation":2},
	   "spec":{"replicas":2},
	   "status":{"observedGeneration":2,"replicas":3,"readyReplicas":2,"availableReplicas":2,
	     "updatedReplicas":1,"unavailableReplicas":1,
	     "conditions":[
	       {"type":"Available","status":"True","reason":"MinimumReplicasAvailable","lastUpdateTime":"2026-08-18T13:48:04Z"},
	       {"type":"Progressing","status":"True","reason":"ReplicaSetUpdated","lastUpdateTime":%q}]}},
	  {"metadata":{"name":"hello-00001-deployment","namespace":"demo","generation":1},
	   "spec":{"replicas":0},"status":{"observedGeneration":1}},
	  {"metadata":{"name":"hello-site","namespace":"demo","generation":1},
	   "spec":{"replicas":1},
	   "status":{"observedGeneration":1,"replicas":1,"readyReplicas":1,"updatedReplicas":1,
	     "conditions":[{"type":"Progressing","status":"True","reason":"NewReplicaSetAvailable",
	       "lastUpdateTime":"2026-08-18T13:50:00Z"}]}}]}`,
		progressedAt.UTC().Format(time.RFC3339))

	const pods = `{"items":[
	  {"metadata":{"name":"demo-web-69dfd9d57c-zm6v2","namespace":"demo"},
	   "status":{"phase":"Running","containerStatuses":[{"name":"web","ready":false,
	     "state":{"waiting":{"reason":"CrashLoopBackOff",
	       "message":"back-off 1m20s restarting failed container=web pod=demo-web-69dfd9d57c-zm6v2_demo"}}}]}},
	  {"metadata":{"name":"demo-web-86c89df498-4k42z","namespace":"demo"},
	   "status":{"phase":"Running","containerStatuses":[{"name":"web","ready":true,"state":{"running":{}}}]}}]}`

	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.URL.Path == "/apis/apps/v1/deployments":
			_, _ = io.WriteString(w, deployments)
		case strings.HasSuffix(r.URL.Path, "/pods"):
			_, _ = io.WriteString(w, pods)
		default:
			// statefulsets, daemonsets, events: nothing in this namespace.
			_, _ = io.WriteString(w, `{"items":[]}`)
		}
	}
}

// withKagent makes the Case file's agent read as present and Healthy, so the
// live mount renders rather than the locked hint.
func withKagent(srv *Server) *Server {
	srv.Kagent = kagent.New("http://kagent.invalid")
	var app kube.ArgoApp
	app.Status.Health.Status = "Healthy"
	srv.snap = kube.Snapshot{Apps: map[string]kube.ArgoApp{"kagent": app}}
	srv.snapAt = time.Now()
	return srv
}

func renderComponent(t *testing.T, srv *Server, ns string) string {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/components/"+ns, nil)
	req.SetPathValue("namespace", ns)
	rec := httptest.NewRecorder()
	handleComponentDetail(srv, rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	return rec.Body.String()
}

// TestComponentDetailStalledRollout is the module-10 regression, end to end
// from the captured API responses to the rendered page.
//
// Rehearsal 4 found that with any scenario injected this page read
// "Operational · 3/3 workloads ready" and offered no Open investigation button
// at all, because the mount condition counted Deployments and the old
// ReplicaSet was still serving. The whole second half of module 10 hangs off
// that button.
func TestComponentDetailStalledRollout(t *testing.T) {
	// The rollout has not moved for five minutes — well past kube.StallAfter,
	// and still half of Kubernetes' own 600 s progressDeadlineSeconds.
	srv := withKagent(newTestServer(t, demoAPI(t, time.Now().Add(-5*time.Minute))))
	html := renderComponent(t, srv, "demo")

	if strings.Contains(html, ">Operational<") {
		t.Error("a component whose release has stalled must not read Operational")
	}
	for _, want := range []string{
		">Degraded<",              // the badge
		"stopped making progress", // why the ready count still says 3/3
		"Open investigation",      // the module-10 centrepiece, reachable at last
		`data-kind="Component"`,
		"Diagnostics",      // the panel that explains the cause
		"CrashLoopBackOff", // ...naming the container that is actually failing
	} {
		if !strings.Contains(html, want) {
			t.Errorf("stalled component page missing %q", want)
		}
	}
}

// The other half of the contract: a component mid-deploy on a healthy cluster
// must not be libelled. The console polls this page's list fragment every 10 s
// and a healthy demo-web roll is in flight for ~14 s, so calling that
// "Degraded" — and offering a why-is-this-broken panel for it — would cry wolf
// on every single push.
func TestComponentDetailHealthyRollDoesNotCryWolf(t *testing.T) {
	srv := withKagent(newTestServer(t, demoAPI(t, time.Now().Add(-6*time.Second))))
	html := renderComponent(t, srv, "demo")

	if !strings.Contains(html, ">Rolling out<") {
		t.Error("a release in flight should say so")
	}
	for _, unwanted := range []string{">Degraded<", ">Down<", "stopped making progress", "CrashLoopBackOff"} {
		if strings.Contains(html, unwanted) {
			t.Errorf("healthy roll must not render %q", unwanted)
		}
	}
	if !strings.Contains(html, "1 rollout is in progress.") {
		t.Error("the in-flight note should say a rollout is running")
	}
}

// A settled, genuinely healthy component reads Operational and shows no fault
// panel — but STILL offers the investigation. Module 10's third scenario is a
// bad release whose pods all come up Running: if the button only appeared for
// visibly broken things, the one scenario about "green pods are not evidence
// that the release was good" would be the one you could not investigate.
func TestComponentDetailHealthyStillOffersInvestigation(t *testing.T) {
	settled := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/apis/apps/v1/deployments" {
			_, _ = io.WriteString(w, `{"items":[{"metadata":{"name":"demo-web","namespace":"demo","generation":1},
			  "spec":{"replicas":2},
			  "status":{"observedGeneration":1,"replicas":2,"readyReplicas":2,"availableReplicas":2,"updatedReplicas":2,
			    "conditions":[{"type":"Progressing","status":"True","reason":"NewReplicaSetAvailable",
			      "lastUpdateTime":"2026-08-18T13:48:04Z"}]}}]}`)
			return
		}
		_, _ = io.WriteString(w, `{"items":[]}`)
	}
	html := renderComponent(t, withKagent(newTestServer(t, settled)), "demo")

	if !strings.Contains(html, ">Operational<") {
		t.Error("a settled, fully ready component must read Operational")
	}
	for _, unwanted := range []string{"Rolling out", "rollout is in progress", ">Diagnostics<"} {
		if strings.Contains(html, unwanted) {
			t.Errorf("healthy component must not render %q", unwanted)
		}
	}
	if !strings.Contains(html, "Open investigation") {
		t.Error("the investigation must stay reachable on a component that merely LOOKS fine")
	}
}
