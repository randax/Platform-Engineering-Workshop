package web

// Hermetic tests for the Case file — the single-shot agent investigation on the
// application-detail page (module 10). A scripted fake Kagent (httptest) stands
// in for the controller; no cluster, no real Kagent, no LLM. We assert the
// browser-facing SSE event sequence + rendered fragments (happy path), the
// readable failure state (agent unreachable), the locked affordance when the
// capability is absent, and that the fix is copy-paste git — no mutating action.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"cloudbox.io/portal/internal/kagent"
	"cloudbox.io/portal/internal/kube"
)

// fakeKagent is a scripted A2A controller: it emits the canned SSE frames and
// counts how many times it was called (so a "no backend call" claim is real).
func fakeKagent(t *testing.T, sse string) (*httptest.Server, *int) {
	t.Helper()
	calls := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Header().Set("Content-Type", "text/event-stream")
		if _, err := w.Write([]byte(sse)); err != nil {
			t.Errorf("write sse: %v", err)
		}
	}))
	t.Cleanup(ts.Close)
	return ts, &calls
}

const investigationSSE = `data: {"result":{"type":"tool_call","tool":"k8s_get_resources","args":"pods -n demo-app"}}

data: {"result":{"type":"tool_result","output":"0/1 Running 7 restarts","observation":"7 restarts in 11 minutes"}}

data: {"result":{"type":"message","text":"forming a hypothesis"}}

data: {"result":{"type":"verdict","verdict":{"status":"Diagnosed — unverified","hypothesis":"memory limit 48Mi is below the real working set","killTest":"kubectl -n demo-app get pod -o jsonpath='{..lastState.terminated.reason}'","fix":"git revert HEAD\ngit push"}}}

data: {"result":{"type":"done","final":true}}

`

// serverWithKagent builds a Server whose snapshot reports the kagent capability
// (un)available, with templates parsed and a Kagent client pointed at base.
func serverWithKagent(t *testing.T, base string, available bool) *Server {
	t.Helper()
	s := &Server{Kagent: kagent.New(base)}
	tmpl, err := ParseTemplates(s)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	s.Tmpl = tmpl
	apps := map[string]kube.ArgoApp{}
	if available {
		apps["kagent"] = fixtureApp("kagent", "Healthy")
	}
	// Seed the unlock cache so currentSnapshot (Kube is nil) returns it.
	s.snap = kube.Snapshot{Apps: apps}
	s.snapAt = time.Now()
	return s
}

func askRequest(t *testing.T) *http.Request {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"namespace": "demo-app", "kind": "Application", "name": "demo-app"})
	return httptest.NewRequest(http.MethodPost, "/agent/ask", bytes.NewReader(body))
}

// indexOrder asserts each marker appears in body, in the given order.
func indexOrder(t *testing.T, body string, markers ...string) {
	t.Helper()
	prev := -1
	for _, m := range markers {
		i := strings.Index(body, m)
		if i < 0 {
			t.Errorf("missing marker %q in stream:\n%s", m, body)
			continue
		}
		if i < prev {
			t.Errorf("marker %q out of order in stream:\n%s", m, body)
		}
		prev = i
	}
}

func TestAgentAskHappyPath(t *testing.T) {
	ts, calls := fakeKagent(t, investigationSSE)
	s := serverWithKagent(t, ts.URL, true)

	rec := httptest.NewRecorder()
	HandleAgentAsk(s, rec, askRequest(t))

	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/event-stream") {
		t.Errorf("Content-Type = %q, want text/event-stream", ct)
	}
	if *calls != 1 {
		t.Errorf("kagent called %d times, want 1", *calls)
	}
	body := rec.Body.String()
	// The browser SSE event sequence.
	indexOrder(t, body,
		"event: tool_call",
		"event: tool_result",
		"event: message",
		"event: verdict",
		"event: done",
	)
	// The rendered fragments carry the investigation content.
	for _, want := range []string{
		"k8s_get_resources",           // the tool call
		"7 restarts in 11 minutes",    // the observation
		"48Mi",                        // the hypothesis
		"kubectl -n demo-app get pod", // the kill-test
		"git revert HEAD",             // the fix — copy-paste git
		"git push",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("stream missing fragment content %q", want)
		}
	}
	// The fix must never be a mutating affordance — no apply button, no form post.
	for _, forbidden := range []string{"hx-post", "hx-delete", "<button", "<form", "kubectl apply"} {
		if strings.Contains(body, forbidden) {
			t.Errorf("case file must not offer a mutating action, found %q", forbidden)
		}
	}
}

func TestAgentAskAgentUnreachable(t *testing.T) {
	// Capability present, but the controller refuses connections → a readable
	// failure state in the stream (an error event), no verdict.
	s := serverWithKagent(t, "http://127.0.0.1:1", true)
	s.Kagent = kagent.New("http://127.0.0.1:1")

	rec := httptest.NewRecorder()
	HandleAgentAsk(s, rec, askRequest(t))

	body := rec.Body.String()
	if !strings.Contains(body, "event: error") {
		t.Errorf("unreachable agent must produce an error event:\n%s", body)
	}
	if strings.Contains(body, "event: verdict") {
		t.Errorf("a failed investigation must not render a verdict:\n%s", body)
	}
}

func TestAgentAskLockedNoBackendCall(t *testing.T) {
	// The capability is absent from the snapshot. The endpoint must refuse to
	// call the backend at all — the guard behind the locked affordance.
	ts, calls := fakeKagent(t, investigationSSE)
	s := serverWithKagent(t, ts.URL, false)

	rec := httptest.NewRecorder()
	HandleAgentAsk(s, rec, askRequest(t))

	if *calls != 0 {
		t.Errorf("locked capability must make no backend call, got %d", *calls)
	}
	if !strings.Contains(rec.Body.String(), "event: error") {
		t.Errorf("locked capability should answer with an error event:\n%s", rec.Body.String())
	}
}

func TestBuildInvestigationPrompt(t *testing.T) {
	diag := kube.Diagnostics{PodTroubles: []kube.PodTrouble{{
		Pod: "demo-app-x8k2p", Container: "app", Reason: "OOMKilled",
		Message: "terminated (exit 137)",
	}}}
	p := buildInvestigationPrompt("Application", "demo-app", "demo-app",
		"composed Deployment is not Available", diag, "")
	for _, want := range []string{
		"Application", "demo-app", // the resource identity
		"composed Deployment is not Available", // the condition (why)
		"OOMKilled", "demo-app-x8k2p",          // the diagnostics rollup
		"git",       // the fix must be framed as git commands
		"read-only", // the read-only guardrail
	} {
		if !strings.Contains(p, want) {
			t.Errorf("prompt missing %q:\n%s", want, p)
		}
	}
}

// TestCaseFileView pins the application-detail affordance: the investigation
// mount when the capability is available, and the locked affordance (with the
// unlock hint, and NO mount that could trigger a backend call) when it isn't.
func TestCaseFileView(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{GrafanaURL: "http://localhost:30030"})
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	base := sampleAppDetail() // an unhealthy, source-built app
	base.ShowCaseFile = true

	// Available: the split-view investigation mount + Open investigation button.
	avail := base
	avail.AgentAvailable = true
	var on bytes.Buffer
	if err := tmpl.ExecuteTemplate(&on, "application-detail", avail); err != nil {
		t.Fatalf("render available: %v", err)
	}
	h := on.String()
	for _, want := range []string{"Case file", `id="case-file"`, "Open investigation", "Kill-test"} {
		if !strings.Contains(h, want) {
			t.Errorf("available Case file missing %q", want)
		}
	}

	// Absent: the locked affordance with an unlock hint, and no mount.
	locked := base
	locked.AgentAvailable = false
	var off bytes.Buffer
	if err := tmpl.ExecuteTemplate(&off, "application-detail", locked); err != nil {
		t.Fatalf("render locked: %v", err)
	}
	l := off.String()
	if !strings.Contains(l, "kagent") {
		t.Errorf("locked affordance must name the unlock (kagent):\n%s", l)
	}
	if strings.Contains(l, `id="case-file"`) || strings.Contains(l, "Open investigation") {
		t.Errorf("locked affordance must not render an investigation mount")
	}
}
