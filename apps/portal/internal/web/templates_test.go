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
	tmpl, err := ParseTemplates(&Server{GrafanaURL: "http://grafana.cloudbox.k8s.test"})
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
				`>Platform</span>`, `>Services</span>`, `>Capstone</span>`,
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
			data: functionsData{
				Rows: []serviceRow{
					{KnativeService: kube.KnativeService{Metadata: kube.ObjMeta{Name: "fn-hello", Namespace: "demo"}}, Deletable: true, Spark: metrics.Sparkline([]float64{0, 1, 2, 1}, "request rate"), Grafana: "http://grafana/explore?x"},
					{}, // uninstrumented service: no metrics
				},
				Samples: fnSamples,
			},
			want: []string{
				`Not ready`,                      // empty conditions: amber fallback, not a red "False"
				`<svg class="spark"`, `polyline`, // server-rendered sparkline
				`— no metrics yet`, // the required empty state
				`traces →`,         // Grafana Tempo deep link
				// merged lifecycle: build form + invoke + delete (demo ns only)
				`hx-post="/services"`,
				`Build &amp; deploy`,
				`/services/demo/fn-hello/invoke`,      // invoke wakes it server-side
				`hx-delete="/services/demo/fn-hello"`, // delete targets the row's own namespace
			},
		},
		"applications": {
			data: sampleApplications(),
			want: []string{
				`hx-trigger="every 5s"`,                  // the list polls itself
				`hx-post="/applications"`,                // the rich create form
				`name="image"`, `Min scale`, `Max scale`, // the fuller input set
				`name="source"`, `Build from a repo`, `name="repo"`, // deploy-from-source toggle
				`Attach a Postgres database`, `Attach an S3 bucket`, // dependency toggles
				`web-demo.kn.cloudbox.k8s.test`, // the Ready app's URL
				`href="/applications/web"`,      // name + Details link into the detail view
				`hx-delete="/applications/web"`, // per-row delete
			},
		},
		"application-detail": {
			data: sampleAppDetail(),
			want: []string{
				`Composed resources`,                   // the composition hub
				`href="/databases/api"`,                // cross-link to the composed database
				`href="/buckets/api-data"`,             // cross-link to the composed bucket
				`Diagnostics`,                          // the "why", moved here off the list
				`ImagePullBackOff`,                     // the pod-trouble cause
				`hx-post="/applications/api/redeploy"`, // Redeploy lives on the detail now
				`hx-delete="/applications/api"`,        // delete from the danger zone
				`polyline`,                             // the monitoring sparkline (Telemetry branch)
				`api-demo.kn.cloudbox.k8s.test`,        // the Ready workload URL
			},
		},
		"function-detail": {
			data: sampleFnDetail(),
			want: []string{
				`Diagnostics`,                         // the "why" (ShowDiag branch)
				`ImagePullBackOff`,                    // the pod-trouble cause
				`polyline`,                            // the monitoring sparkline (Telemetry branch)
				`idle · 0 pods`,                       // scale-from-zero
				`/services/demo/fn-hello/invoke`,      // Invoke wakes it server-side
				`hx-delete="/services/demo/fn-hello"`, // delete targets the function's own namespace
			},
		},
		"database-detail": {
			data: dbDetailData{
				Name: "my-db", DB: &db, ClusterName: "my-db-pg",
				Cluster:    &kube.CNPGClusterDetail{}, // composed: Connect + Monitoring show
				Secret:     "my-db-pg-app",
				Psql:       "kubectl -n demo exec -it my-db-pg-1 -- psql -U app app",
				Events:     []kube.Event{{Type: "Warning", Reason: "FailedScheduling", Message: "0/2 nodes"}},
				GrafanaURL: "http://grafana.cloudbox.k8s.test/explore?x",
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
				// resize: the form + the current size pre-selected
				`hx-post="/databases/my-db/resize"`, `value="small" selected`, `Apply size`,
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
				`<svg class="ico"`, // the lock icon (replaced the 🔒 emoji)
				`Services`,         // the locked page title
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

// TestProjectNameFormMatchesServerRule pins the project-name form control to
// the SERVER's rule (kube.ValidProjectName / kube.ValidName).
//
// The form carried pattern="[a-z0-9]+" with no length cap at all, while
// kube.ValidName's regexp caps a name at 40 characters. A 41-character project
// name therefore passed browser validation, was POSTed, and came back as a
// server-side error the form gives no hint about. The two halves of one rule
// have to be written down twice (HTML cannot ask Go), so this asserts they
// still agree — and that the numbers in the pattern are the ones the server
// actually enforces.
func TestProjectNameFormMatchesServerRule(t *testing.T) {
	src, err := templateFS.ReadFile("templates/project-bar.html")
	if err != nil {
		t.Fatalf("reading project-bar.html: %v", err)
	}
	html := string(src)
	for _, want := range []string{`pattern="[a-z0-9]{1,40}"`, `maxlength="40"`} {
		if !strings.Contains(html, want) {
			t.Errorf("project-bar.html is missing %s — the form must carry the server's own length cap", want)
		}
	}

	// And the numbers are right: 40 accepted, 41 refused, by the SERVER.
	if !kube.ValidProjectName(strings.Repeat("a", 40)) {
		t.Errorf("kube.ValidProjectName(40 chars) = false; the form's {1,40} would let it through")
	}
	if kube.ValidProjectName(strings.Repeat("a", 41)) {
		t.Errorf("kube.ValidProjectName(41 chars) = true; the form's {1,40} is stricter than the server")
	}
	// The hyphen half of the same rule, still asserted from both sides.
	if kube.ValidProjectName("team-a") {
		t.Errorf("kube.ValidProjectName(%q) = true; the form's [a-z0-9] excludes it", "team-a")
	}
}
