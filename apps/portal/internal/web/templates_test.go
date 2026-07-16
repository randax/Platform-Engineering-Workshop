package web

import (
	"bytes"
	"strings"
	"testing"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/metrics"
	"cloudbox.io/portal/internal/store"
)

// fixtureApp builds an ArgoCD Application fixture (same helper the kube
// package tests use).
func fixtureApp(name, health string) kube.ArgoApp {
	a := kube.ArgoApp{}
	a.Metadata.Name = name
	a.Status.Health.Status = health
	return a
}

// Executes every page template with representative data, so a typo in a
// template or a renamed struct field fails `go test` instead of a live page.
// For the interactive fragments it also asserts the UX-critical markup:
// delete confirmation, the htmx polling attributes, and the analysis output.
func TestTemplatesRender(t *testing.T) {
	// Same constructor main uses (FuncMap!). A bare Server with just the
	// Grafana URL is enough: with no Kube client currentSnapshot returns the
	// zero snapshot, so the nav renders with every gated page simply locked.
	tmpl, err := ParseTemplates(&Server{GrafanaURL: "http://localhost:30030"})
	if err != nil {
		t.Fatalf("parsing templates: %v", err)
	}

	app := kube.ArgoApp{}
	app.Metadata.Name = "gitea"
	app.Status.Sync.Status = "Synced"
	app.Status.Health.Status = "Healthy"

	db := kube.WorkshopDB{}
	db.Metadata.Name = "my-db"
	db.Spec.Size = "small"
	db.Spec.StorageGB = 1
	db.Status.Conditions = []kube.Condition{{Type: "Ready", Status: "False", Reason: "Creating"}}

	pages := map[string]struct {
		data any
		want []string // substrings the rendered HTML must contain
	}{
		"overview": {
			data: map[string]any{
				"Apps":    []kube.ArgoApp{app},
				"Summary": kube.ClusterSummary{Namespaces: 3, Pods: 10, PodsRunning: 9},
			},
			want: []string{
				`aria-current="page"`,
				// the sidebar's grouped sections
				`>Platform</span>`, `>Self-service</span>`, `>Capstone</span>`,
				`href="/components"`, `href="/workshop"`,
				`href="/activity"`, `href="/billing"`,
				`Grafana →`, // rail footer deep link
			},
		},
		"components": {
			data: splitRows(componentRows(map[string]kube.NSHealth{
				"kube-system": {Ready: 3, Total: 3},
				"pipeline":    {Ready: 1, Total: 2},
				"rustfs":      {Ready: 0, Total: 1},
			})),
			want: []string{
				`hx-trigger="every 10s"`, // statuspage polls itself
				`dot ok`, `>Operational</span>`,
				`dot meh`, `>Degraded</span>`,
				`dot bad`, `>Down</span>`,
				`dot off`, `>Not installed</span>`,
				`>Running</h2>`, `Marketplace <small>— one file away</small>`,
				`enable gitops/catalog/crossplane.yaml`, // hint for missing components
			},
		},
		"workshop": {
			data: workshopData{Modules: kube.EvaluateModules(kube.Snapshot{
				Apps:       map[string]kube.ArgoApp{"platform": fixtureApp("platform", "Healthy")},
				NodesTotal: 2, NodesReady: 2, KubeProxyPods: 2,
			})},
			want: []string{
				`hx-trigger="every 10s"`,
				`the authoritative check`, // the honesty banner
				`>Done</span>`, `>In progress</span>`, `>Not started</span>`, `>Manual check</span>`,
				`lab/05-debug-with-ai/verify.sh`,
			},
		},
		"workshop-list": {
			data: workshopData{Flash: flash{Msg: "boom", Error: true}},
			want: []string{`flash-error`},
		},
		"databases": {
			data: databasesData{
				Clusters:  []kube.CNPGCluster{{}},
				Databases: []kube.WorkshopDB{db},
				Namespace: kube.XRNamespace,
			},
			want: []string{
				`hx-trigger="every 5s"`,   // the tables poll themselves
				`>Creating</span>`,        // condition Reason, not a red "False"
				`href="/databases/my-db"`, // rows link to the detail page
			},
		},
		"db-list": {
			data: databasesData{Flash: flash{Msg: "boom", Error: true}},
			want: []string{`flash-error`, `No databases yet`},
		},
		"gallery": {
			data: galleryData{Items: []store.Item{
				{Key: "originals/1-cat.png", Name: "1-cat.png", URL: "http://x", ThumbURL: "http://y",
					Meta: &store.ImageMeta{Width: 800, Height: 600, Format: "jpeg", Bytes: 250880, DominantColor: "#aabbcc"}},
				{Key: "originals/2-dog.png", Name: "2-dog.png"}, // not yet processed
			}},
			want: []string{
				`hx-trigger="every 5s"`,   // grid polls itself
				`800×600 · jpeg · 245 KB`, // the resizer's analysis, humanized
				`background:#aabbcc`,      // dominant-color swatch
				`Thumbnail of 1-cat.png`,  // real alt text
				`accept="image/jpeg,image/png"`,
				`waiting for the resizer`,
			},
		},
		"gallery-grid": {
			data: galleryData{},
			want: []string{`Nothing here yet — upload the first image.`},
		},
		"services": {
			data: []serviceRow{
				{Spark: metrics.Sparkline([]float64{0, 1, 2, 1}, "request rate"), Grafana: "http://grafana/explore?x"},
				{}, // uninstrumented service: no metrics
			},
			want: []string{
				`Not ready`,                      // empty conditions: amber fallback, not a red "False"
				`<svg class="spark"`, `polyline`, // server-rendered sparkline
				`— no metrics yet`, // the required empty state
				`traces →`,         // Grafana Tempo deep link
			},
		},
		"database-detail": {
			data: dbDetailData{
				Name: "my-db", DB: &db, ClusterName: "my-db-pg",
				Cluster:    &kube.CNPGClusterDetail{}, // composed: Connect + Monitoring show
				Secret:     "my-db-pg-app",
				Psql:       "kubectl -n demo exec -it my-db-pg-1 -- psql -U app app",
				Events:     []kube.Event{{Type: "Warning", Reason: "FailedScheduling", Message: "0/2 nodes"}},
				GrafanaURL: "http://localhost:30030/explore?x",
				Telemetry:  true,
				ConnSpark:  metrics.Sparkline([]float64{1, 3, 2, 4}, "connections"),
				ConnNow:    "4",
				CacheSpark: metrics.Sparkline([]float64{99.2, 99.5, 99.4, 99.7}, "cache hit ratio"),
				CacheNow:   "99.7%",
				SizeNow:    "12 MiB",
			},
			want: []string{
				`hx-confirm`, `Delete this database`, // destructive action lives HERE now
				`my-db-pg-app`,    // connection secret
				`psql -U app app`, // paste-ready one-liner
				`evwarn`,          // warning event tinted
				`Monitoring`, `Connections`, `Database size`, `Explore in Grafana`,
			},
		},
		"activity": {
			data: activityData{Events: []kube.Event{
				{Type: "Warning", Reason: "BackOff", Message: "restarting container", Count: 3},
				{Type: "Normal", Reason: "Created", Message: "created pod"},
			}},
			want: []string{
				`hx-trigger="every 10s"`,
				`evwarn`, `BackOff`, `×3`,
				`CloudTrail-lite`,
			},
		},
		"activity-list": {
			data: activityData{},
			want: []string{`a quiet cluster is a happy cluster`}, // empty state
		},
		"billing": {
			data: billingData{Month: "July 2026", DBCount: 2, Nodes: []kube.NodeUsage{
				{Name: "cloudbox-worker", CPUReq: 1500, CPUAlloc: 4000, MemReq: 3 << 30, MemAlloc: 8 << 30},
			}},
			want: []string{
				`Invoice — July 2026`,
				`kr 0,00`, `also no`, `it's your hardware`,
				`2 provisioned`, // managed databases count
				`width: 37%`,    // 1500/4000 requests bar
				`1500m of 4000m requested`,
				`fineprint`, `which on kr 0,00 is kr 0,00`, // egg
			},
		},
		"locked": {
			data: lockedData{
				Title:  "Services",
				Key:    "services",
				Hint:   "Complete Module 06 · Serverless",
				Teaser: "Deploy serverless workloads that scale to zero.",
			},
			want: []string{
				`🔒 Services`,
				`Deploy serverless workloads that scale to zero.`, // teaser
				`Complete Module 06 · Serverless`,                 // unlock hint
			},
		},
		"notfound": {data: nil, want: []string{"This page scaled to zero.", `class="rail"`}},
		"error":    {data: "boom", want: []string{"boom"}},
	}

	for name, tc := range pages {
		var buf bytes.Buffer
		if err := tmpl.ExecuteTemplate(&buf, name, tc.data); err != nil {
			t.Errorf("rendering %q: %v", name, err)
			continue
		}
		for _, want := range tc.want {
			if !strings.Contains(buf.String(), want) {
				t.Errorf("%q: rendered HTML missing %q", name, want)
			}
		}
	}
}
