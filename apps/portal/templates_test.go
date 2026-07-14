package main

import (
	"bytes"
	"strings"
	"testing"
)

// Executes every page template with representative data, so a typo in a
// template or a renamed struct field fails `go test` instead of a live page.
// For the interactive fragments it also asserts the UX-critical markup:
// delete confirmation, the htmx polling attributes, and the analysis output.
func TestTemplatesRender(t *testing.T) {
	tmpl, err := parseTemplates() // same constructor main uses (FuncMap!)
	if err != nil {
		t.Fatalf("parsing templates: %v", err)
	}

	app := argoApp{}
	app.Metadata.Name = "gitea"
	app.Status.Sync.Status = "Synced"
	app.Status.Health.Status = "Healthy"

	db := workshopDB{}
	db.Metadata.Name = "my-db"
	db.Spec.Size = "small"
	db.Spec.StorageGB = 1
	db.Status.Conditions = []condition{{Type: "Ready", Status: "False", Reason: "Creating"}}

	pages := map[string]struct {
		data any
		want []string // substrings the rendered HTML must contain
	}{
		"overview": {
			data: map[string]any{
				"Apps":    []argoApp{app},
				"Summary": clusterSummary{Namespaces: 3, Pods: 10, PodsRunning: 9},
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
			data: splitRows(componentRows(map[string]nsHealth{
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
			data: workshopData{Modules: evaluateModules(snapshot{
				apps:       map[string]argoApp{"platform": fixtureApp("platform", "Healthy")},
				nodesTotal: 2, nodesReady: 2, kubeProxyPods: 2,
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
				Clusters:  []cnpgCluster{{}},
				Databases: []workshopDB{db},
				Namespace: xrNamespace,
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
			data: galleryData{Items: []galleryItem{
				{Key: "originals/1-cat.png", Name: "1-cat.png", URL: "http://x", ThumbURL: "http://y",
					Meta: &imageMeta{Width: 800, Height: 600, Format: "jpeg", Bytes: 250880, DominantColor: "#aabbcc"}},
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
				{Spark: sparkline([]float64{0, 1, 2, 1}), Grafana: "http://grafana/explore?x"},
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
				Secret: "my-db-pg-app",
				Psql:   "kubectl -n demo exec -it my-db-pg-1 -- psql -U app app",
				Events: []k8sEvent{{Type: "Warning", Reason: "FailedScheduling", Message: "0/2 nodes"}},
			},
			want: []string{
				`hx-confirm`, `Delete this database`, // destructive action lives HERE now
				`my-db-pg-app`,    // connection secret
				`psql -U app app`, // paste-ready one-liner
				`evwarn`,          // warning event tinted
				`Explore metrics in Grafana`,
			},
		},
		"activity": {
			data: activityData{Events: []k8sEvent{
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
			data: billingData{Month: "July 2026", DBCount: 2, Nodes: []nodeUsage{
				{Name: "cloudbox-worker", CPUReq: 1500, CPUAlloc: 4000, MemReq: 3 << 30, MemAlloc: 8 << 30},
			}},
			want: []string{
				`Invoice — July 2026`,
				`kr 0,00`, `also no`, `it's your hardware`,
				`2 provisioned`, // managed databases count
				`width: 37%`,    // 1500/4000 requests bar
				`1500m of 4000m requested`,
			},
		},
		"error": {data: "boom", want: []string{"boom"}},
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

func TestReadinessOf(t *testing.T) {
	cases := []struct {
		conds []condition
		want  readiness
	}{
		{[]condition{{Type: "Ready", Status: "True"}}, readiness{"Ready", "ok"}},
		{[]condition{{Type: "Ready", Status: "False", Reason: "Creating"}}, readiness{"Creating", "meh"}},
		{[]condition{{Type: "Ready", Status: "Unknown", Reason: "Deploying"}}, readiness{"Deploying", "meh"}},
		{[]condition{{Type: "Ready", Status: "False"}}, readiness{"Not ready", "meh"}},
		{nil, readiness{"Not ready", "meh"}},
	}
	for _, c := range cases {
		if got := readinessOf(c.conds); got != c.want {
			t.Errorf("readinessOf(%v) = %v, want %v", c.conds, got, c.want)
		}
	}
}
