package web

// The Functions page: Knative Services with request-rate/latency sparklines,
// scale-from-zero, one-click Grafana traces — plus the full lifecycle a cloud
// console gives you: build-and-deploy a new function (Argo Workflows + BuildKit
// → Knative), invoke one (server-side GET that wakes it from zero), and delete
// one. It absorbed the standalone "New Function" page (#58) so everything about
// a function lives in one place.

import (
	"fmt"
	"html/template"
	"io"
	"net/http"
	"time"

	"cloudbox.io/portal/internal/kube"
	"cloudbox.io/portal/internal/metrics"
)

func init() {
	register(Page{
		Weight:     64,
		NavSection: "Services",
		NavTitle:   "Functions",
		Path:       "/services",
		Handler:    handleServices,
		// Serverless (module 06): nothing to list until Knative Serving is
		// installed and Healthy — the ksvc CRD doesn't even exist before then.
		// (The build half of the create form additionally needs Argo Workflows
		// from module 07; if it's missing the create simply flashes an error.)
		Unlock:     func(s kube.Snapshot) bool { _, h := s.AppHealthy("knative-serving"); return h },
		LockedHint: "Complete Module 06 · Serverless",
		Teaser:     "Deploy serverless workloads that scale to zero and back — build, invoke and delete functions, with request-rate sparklines and one-click Grafana trace links.",
		// Mutating routes. Like the databases form, no CSRF token — single-user
		// disposable lab; don't copy this into a real portal.
		Extra: []Route{
			{"GET /services/list", handleServicesList}, // polled by htmx
			{"POST /services", handleCreateFunction},   // build & deploy
			{"POST /services/{namespace}/{name}/invoke", handleInvokeFunction},
			{"DELETE /services/{name}", handleDeleteFunction}, // demo ns only (RBAC)
		},
	})
}

// serviceRow decorates a Knative Service with its request-rate sparkline
// and a Grafana trace-search link. Instrumented services report to
// Prometheus under job = OTEL_SERVICE_NAME = "cloudbox-<name>"; anything
// uninstrumented simply has no series and renders the empty-state dash.
type serviceRow struct {
	kube.KnativeService
	Spark      template.HTML // request rate, last 30 min
	Latency    template.HTML // p95 request latency, last 30 min
	LatencyNow string        // the latest p95, in ms
	Scale      string        // current desired pods: "idle (0)" or "N running"
	Grafana    string
}

// functionsData is the Functions page model: the live rows, the whitelisted
// build sources for the create form, and a one-shot flash.
type functionsData struct {
	Rows    []serviceRow
	Samples []fnSample
	Flash   flash
}

// fnSample is one vetted, in-cluster source a function can be built from. The
// repo MUST be an in-cluster Gitea URL (never github.com) — the whole platform
// is offline, and BuildKit clones from inside the cluster. Server-side
// whitelist: the browser only ever submits a key, never a raw repo/path, so a
// crafted form can't point a build at an arbitrary URL.
type fnSample struct {
	Key, Label, Repo, Path, Desc string
}

var fnSamples = []fnSample{
	{
		Key:   "hello-site",
		Label: "hello-site — static page on busybox httpd",
		Repo:  "http://gitea-http.gitea.svc.cluster.local:3000/cloudbox/platform.git",
		Path:  "lab/07-ci/app",
		Desc:  "Module 07's sample: a tiny static site, built FROM your own Zot registry and served on :8080.",
	},
}

func lookupSample(key string) (fnSample, bool) {
	for _, s := range fnSamples {
		if s.Key == key {
			return s, true
		}
	}
	return fnSample{}, false
}

// fetchFunctions lists the Knative Services and decorates each with its
// best-effort metrics. All Prometheus queries degrade to the empty-state dash
// on error — the page renders whether or not the observability stack is on.
func fetchFunctions(s *Server, r *http.Request, fl flash) (functionsData, error) {
	svcs, err := s.Kube.ListKnativeServices(r.Context())
	if err != nil {
		return functionsData{}, err
	}
	rows := make([]serviceRow, 0, len(svcs))
	for _, k := range svcs {
		job := "cloudbox-" + k.Metadata.Name
		row := serviceRow{KnativeService: k, Grafana: grafanaTraces(s.GrafanaURL, job)}
		// Sparkline is best-effort: a prom error means the same thing as no
		// data — the dash renders, the page never fails over decoration.
		if vals, err := s.Prom.QueryRange(r.Context(), metrics.RequestRateQuery(job)); err == nil {
			row.Spark = metrics.Sparkline(vals, "request rate")
		}
		// Mean latency from the same histogram (best-effort, same as the rate).
		if vals, err := s.Prom.QueryRange(r.Context(), metrics.LatencyAvgQuery(job)); err == nil && len(vals) > 0 {
			row.Latency = metrics.Sparkline(vals, "avg latency")
			row.LatencyNow = fmt.Sprintf("%.0f ms", vals[len(vals)-1]*1000)
		}
		// Scale-from-zero: the current desired pods (#65 Knative metrics, #58/#83).
		// Keyed by the ksvc's own name, not the OTLP service name. 0 = scaled to
		// zero (the serverless payoff made visible); best-effort like the rest.
		if vals, err := s.Prom.QueryRange(r.Context(), metrics.KnativeDesiredPodsQuery(k.Metadata.Name)); err == nil && len(vals) > 0 {
			if n := vals[len(vals)-1]; n < 0.5 {
				row.Scale = "idle · 0 pods"
			} else {
				row.Scale = fmt.Sprintf("%.0f running", n)
			}
		}
		rows = append(rows, row)
	}
	return functionsData{Rows: rows, Samples: fnSamples, Flash: fl}, nil
}

func handleServices(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := fetchFunctions(s, r, flash{})
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "services", data)
}

// handleServicesList serves the self-refreshing table fragment htmx polls every
// 5 s. On error it renders the fragment with an error flash rather than a full
// error page, so the polling attributes stay in the DOM and the table heals
// itself once the API answers again — same pattern as the databases list.
func handleServicesList(s *Server, w http.ResponseWriter, r *http.Request) {
	data, err := fetchFunctions(s, r, flash{})
	if err != nil {
		data = functionsData{Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "svc-list", data)
}

// handleCreateFunction is the fan-out (issue #58): one submit creates the build
// Workflow AND the Knative Service. We create the build first (nothing to run
// without an image); if that's forbidden (the attendee hasn't granted the
// portal write access yet, or module 07 isn't installed) we stop there with a
// friendly flash. The ksvc is admitted immediately (its image host is in
// Knative's tag-resolution skip list) and converges from ImagePullBackOff to
// Ready the moment the build pushes. The response is the refreshed list
// fragment, which htmx swaps in place — so the new fn-<name> row appears at once.
func handleCreateFunction(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.FormValue("name")
	sample, ok := lookupSample(r.FormValue("sample"))
	var fl flash
	switch {
	case !ok:
		fl = errorFlash("Unknown source — pick one of the listed samples.")
	default:
		fl = createFunction(s, r, name, sample)
	}
	data, err := fetchFunctions(s, r, fl)
	if err != nil {
		data = functionsData{Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "svc-list", data)
}

// createFunction submits the two objects and returns the flash describing the
// outcome. Split out so the handler stays about rendering.
func createFunction(s *Server, r *http.Request, name string, sample fnSample) flash {
	if err := s.Kube.CreateFunctionWorkflow(r.Context(), name, sample.Repo, sample.Path); err != nil {
		return errorFlash("Couldn't start the build: " + err.Error())
	}
	if err := s.Kube.CreateFunctionService(r.Context(), name); err != nil {
		// The build is already running; only the deploy half failed. Say so —
		// re-submitting after granting access will create the ksvc, and the
		// finished image is waiting for it.
		return errorFlash("Build started, but deploying the function failed: " + err.Error())
	}
	return flash{Msg: "Building fn-" + name + " and deploying it as a Knative Service. Watch the build on the Builds page; the URL turns Ready below once the image lands (~1 min)."}
}

// invokeResult is the outcome of a server-side function invocation — the little
// "Test" panel every cloud console has. A cold start is the interesting case:
// the GET below wakes a scaled-to-zero function and blocks until it answers.
type invokeResult struct {
	Name     string
	Status   string // e.g. "200 OK"
	Class    string // badge colour: ok / bad
	Duration string
	Body     string // first 2 KiB of the response
	Error    string
}

// invokeClient has a generous timeout: a scale-from-zero cold start (pull +
// boot) can take a few seconds, and blocking on it is the whole point — the
// attendee sees the pod appear while this request hangs, then the response.
var invokeClient = &http.Client{Timeout: 35 * time.Second}

// functionClusterURL is the in-cluster address of a Knative Service. Knative
// programs the cluster-local gateway to route this host to the revision, waking
// it from zero — so a GET here is the canonical way to invoke a ksvc from
// inside the cluster (no ingress, no sslip.io, works headless in CI).
func functionClusterURL(namespace, name string) string {
	return fmt.Sprintf("http://%s.%s.svc.cluster.local", name, namespace)
}

// handleInvokeFunction does a server-side GET against the function's
// cluster-local URL and renders the status + a snippet of the body. Doing it
// server-side (not a browser fetch) keeps the offline, no-CORS, cluster-DNS
// story intact and lets any listed function — including capstone ksvcs in
// `pipeline` — be poked from the console.
func handleInvokeFunction(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	namespace := r.PathValue("namespace")
	if !kube.ValidName(name) || !kube.ValidName(namespace) {
		s.render(w, "invoke-result", invokeResult{Name: name, Error: "Invalid service name."})
		return
	}
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, functionClusterURL(namespace, name), nil)
	if err != nil {
		s.render(w, "invoke-result", invokeResult{Name: name, Error: err.Error()})
		return
	}
	start := time.Now()
	resp, err := invokeClient.Do(req)
	res := invokeResult{Name: name, Duration: time.Since(start).Round(time.Millisecond).String()}
	if err != nil {
		res.Error = "Request failed: " + err.Error()
		s.render(w, "invoke-result", res)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
	res.Status = resp.Status
	res.Class = "ok"
	if resp.StatusCode >= 400 {
		res.Class = "bad"
	}
	res.Body = string(body)
	s.render(w, "invoke-result", res)
}

// handleDeleteFunction deletes a Knative Service and re-renders the list. Only
// demo-namespace functions expose a Delete button (the template gates on it),
// matching the portal-functions-serve RBAC grant; a stray DELETE for anything
// else just surfaces the API's forbidden error in the flash.
func handleDeleteFunction(s *Server, w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	fl := flash{Msg: "Deleted " + name + "."}
	if err := s.Kube.DeleteKnativeService(r.Context(), name); err != nil {
		fl = errorFlash("Delete failed: " + err.Error())
	}
	data, err := fetchFunctions(s, r, fl)
	if err != nil {
		data = functionsData{Flash: errorFlash("API error: " + err.Error())}
	}
	s.render(w, "svc-list", data)
}
