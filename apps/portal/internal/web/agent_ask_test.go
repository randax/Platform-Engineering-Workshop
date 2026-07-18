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
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"cloudbox.io/portal/internal/kagent"
	"cloudbox.io/portal/internal/kube"
)

// fakeKagent is a scripted A2A controller: it emits the canned SSE frames,
// counts how many times it was called (so a "no backend call" claim is real),
// and records the X-User-ID of each call (so distinct sessions can be proven).
func fakeKagent(t *testing.T, sse string) (*httptest.Server, *int, *[]string) {
	t.Helper()
	calls := 0
	var userIDs []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		userIDs = append(userIDs, r.Header.Get("X-User-ID"))
		w.Header().Set("Content-Type", "text/event-stream")
		if _, err := w.Write([]byte(sse)); err != nil {
			t.Errorf("write sse: %v", err)
		}
	}))
	t.Cleanup(ts.Close)
	return ts, &calls, &userIDs
}

const investigationSSE = `data: {"result":{"kind":"tool-call","tool":"k8s_get_resources","args":"pods -n demo-app"}}

data: {"result":{"kind":"tool-result","output":"0/1 Running 7 restarts","observation":"7 restarts in 11 minutes"}}

data: {"result":{"kind":"message","role":"agent","parts":[{"kind":"text","text":"forming a hypothesis"}]}}

data: {"result":{"kind":"message","role":"agent","parts":[{"kind":"data","data":{"verdict":{"status":"Diagnosed — unverified","hypothesis":"memory limit 48Mi is below the real working set","killTest":"kubectl -n demo-app get pod -o jsonpath='{..lastState.terminated.reason}'","fix":"git revert HEAD\ngit push"}}}]}}

data: {"result":{"kind":"status-update","final":true,"status":{"state":"completed"}}}

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
	ts, calls, _ := fakeKagent(t, investigationSSE)
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

// errRoundTripper is a deterministic failing transport: every request errors, so
// "controller unreachable" is exercised with no real socket.
type errRoundTripper struct{}

func (errRoundTripper) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("dial refused (hermetic)")
}

func TestAgentAskAgentUnreachable(t *testing.T) {
	// Capability present, but the controller is unreachable → a readable failure
	// state in the stream (an error event), no verdict.
	s := serverWithKagent(t, "http://unused.invalid", true)
	s.Kagent = kagent.NewWithHTTPClient("http://kagent.invalid", &http.Client{Transport: errRoundTripper{}})

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
	ts, calls, _ := fakeKagent(t, investigationSSE)
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

// emptyStream is an answer made entirely of A2A frames the console doesn't
// translate (a Task, then a clean terminal) — the exact shape a real controller
// produces against the console's invented tool-call format if they diverge.
const emptyStream = `data: {"result":{"kind":"task","id":"t1","status":{"state":"working"}}}

data: {"result":{"kind":"status-update","final":true,"status":{"state":"completed"}}}

`

func TestAgentAskSessionIdentity(t *testing.T) {
	// Each browser session carries a stable, well-shaped cbx_uid; distinct
	// cookies must reach the agent as distinct identities (the verbatim contract:
	// one session per resource per browser session). A missing cookie is minted.
	ts, _, userIDs := fakeKagent(t, investigationSSE)
	s := serverWithKagent(t, ts.URL, true)

	call := func(cookie string) *httptest.ResponseRecorder {
		req := askRequest(t)
		if cookie != "" {
			req.AddCookie(&http.Cookie{Name: "cbx_uid", Value: cookie})
		}
		rec := httptest.NewRecorder()
		HandleAgentAsk(s, rec, req)
		return rec
	}

	alice := strings.Repeat("a", 32) // valid mintID shape (32 lowercase hex)
	bob := strings.Repeat("b", 32)
	call(alice)
	call(bob)
	if len(*userIDs) < 2 || (*userIDs)[0] == (*userIDs)[1] {
		t.Fatalf("two browser sessions must reach the agent as distinct identities: %v", *userIDs)
	}
	if (*userIDs)[0] != alice || (*userIDs)[1] != bob {
		t.Errorf("X-User-ID should carry the browser cookie: %v", *userIDs)
	}

	// No cookie: the handler mints one, sets it, and uses it as the identity.
	rec := call("")
	var set string
	for _, c := range rec.Result().Cookies() {
		if c.Name == "cbx_uid" {
			set = c.Value
		}
	}
	if !uidShape.MatchString(set) {
		t.Fatalf("a missing cbx_uid cookie must be minted well-shaped, got %q", set)
	}
	if got := (*userIDs)[len(*userIDs)-1]; got != set {
		t.Errorf("minted identity %q must be the one sent to the agent (%q)", set, got)
	}
}

func TestAgentAskReplacesInvalidCookie(t *testing.T) {
	// A garbage / oversized cookie is not trusted: the handler mints a fresh
	// well-shaped identity, sets it, and sends THAT to the agent — never the
	// attacker-controlled value.
	ts, _, userIDs := fakeKagent(t, investigationSSE)
	s := serverWithKagent(t, ts.URL, true)

	req := askRequest(t)
	garbage := "../../etc/passwd" + strings.Repeat("A", 5000)
	req.AddCookie(&http.Cookie{Name: "cbx_uid", Value: garbage})
	rec := httptest.NewRecorder()
	HandleAgentAsk(s, rec, req)

	var set string
	for _, c := range rec.Result().Cookies() {
		if c.Name == "cbx_uid" {
			set = c.Value
		}
	}
	if !uidShape.MatchString(set) {
		t.Fatalf("an invalid cookie must be replaced with a well-shaped id, got %q", set)
	}
	if got := (*userIDs)[len(*userIDs)-1]; got != set || got == garbage {
		t.Errorf("agent must receive the minted id (%q), not the garbage cookie (%q)", set, got)
	}
}

func TestAgentAskEmptyStreamSurfacesError(t *testing.T) {
	// The agent answers, but every frame is an A2A shape the console doesn't
	// translate (an envelope mismatch). The stream must not end as a silent
	// "complete" with an empty log — it surfaces a visible error, and no done.
	ts, _, _ := fakeKagent(t, emptyStream)
	s := serverWithKagent(t, ts.URL, true)

	rec := httptest.NewRecorder()
	HandleAgentAsk(s, rec, askRequest(t))

	body := rec.Body.String()
	if !strings.Contains(body, "event: error") {
		t.Errorf("an untranslatable stream must surface an error:\n%s", body)
	}
	if strings.Contains(body, "event: done") {
		t.Errorf("a zero-event stream must not report done:\n%s", body)
	}
}

func TestAgentAskRejectsBadInput(t *testing.T) {
	// Every input that shapes the LLM prompt is validated; a violation is a 400
	// that never reaches the agent.
	ts, calls, _ := fakeKagent(t, investigationSSE)
	s := serverWithKagent(t, ts.URL, true)

	cases := []map[string]string{
		{"namespace": "demo-app", "kind": "Secret", "name": "demo-app"},       // kind not whitelisted
		{"namespace": "Bad NS!", "kind": "Application", "name": "demo-app"},   // non-DNS namespace
		{"namespace": "demo-app", "kind": "Application", "name": "../escape"}, // non-DNS name
	}
	for _, c := range cases {
		b, _ := json.Marshal(c)
		req := httptest.NewRequest(http.MethodPost, "/agent/ask", bytes.NewReader(b))
		rec := httptest.NewRecorder()
		HandleAgentAsk(s, rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("input %v: status = %d, want 400", c, rec.Code)
		}
	}
	if *calls != 0 {
		t.Errorf("rejected inputs must never reach the agent, got %d calls", *calls)
	}
}

func TestAgentAskBoundsRequestBody(t *testing.T) {
	// The ask body is capped, and the free-text question is length-limited on
	// top; both violations are rejected before any upstream call.
	ts, calls, _ := fakeKagent(t, investigationSSE)
	s := serverWithKagent(t, ts.URL, true)

	post := func(raw []byte) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/agent/ask", bytes.NewReader(raw))
		rec := httptest.NewRecorder()
		HandleAgentAsk(s, rec, req)
		return rec
	}

	// A body far over the cap → 413 (MaxBytesReader convention).
	over := append([]byte(`{"namespace":"demo-app","kind":"Application","name":"demo-app","question":"`),
		append(bytes.Repeat([]byte("a"), 8<<10), []byte(`"}`)...)...)
	if rec := post(over); rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("oversized body: status = %d, want 413", rec.Code)
	}

	// A question over the length cap but under the byte cap → 400.
	body, _ := json.Marshal(map[string]string{
		"namespace": "demo-app", "kind": "Application", "name": "demo-app",
		"question": strings.Repeat("q", 2000),
	})
	if rec := post(body); rec.Code != http.StatusBadRequest {
		t.Errorf("over-long question: status = %d, want 400", rec.Code)
	}

	if *calls != 0 {
		t.Errorf("bounded-body rejections must never reach the agent, got %d calls", *calls)
	}
}

func TestAgentAskConvergingLocked(t *testing.T) {
	// kagent is present but not yet Healthy (converging): the gate holds, no
	// backend call, and the message tells the attendee to wait — not to enable it.
	ts, calls, _ := fakeKagent(t, investigationSSE)
	s := serverWithKagent(t, ts.URL, true)
	s.snap = kube.Snapshot{Apps: map[string]kube.ArgoApp{"kagent": fixtureApp("kagent", "Progressing")}}
	s.snapAt = time.Now()

	rec := httptest.NewRecorder()
	HandleAgentAsk(s, rec, askRequest(t))

	if *calls != 0 {
		t.Errorf("a converging agent must make no backend call, got %d", *calls)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, "starting up") {
		t.Errorf("converging state should surface a 'starting up' error:\n%s", body)
	}
}

func TestSanitizeFixCommentsNonGit(t *testing.T) {
	// The Fix contract is copy-paste git only. A kubectl line must survive
	// (nothing dropped silently) but be commented out with a visible warning, so
	// pasting the block can't run it.
	fix := "git revert HEAD\nkubectl -n demo-app patch deploy demo-app --patch '{}'\n# a note\ngit push"
	out := sanitizeFix(fix)
	for _, want := range []string{"git revert HEAD", "git push", "# a note",
		"# ⚠ not a git command — review before running: kubectl -n demo-app patch"} {
		if !strings.Contains(out, want) {
			t.Errorf("sanitizeFix output missing %q:\n%s", want, out)
		}
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "kubectl") {
			t.Errorf("a runnable non-git line survived uncommented: %q", line)
		}
	}
}

func TestAgentAskFixRenderedGitOnly(t *testing.T) {
	// End-to-end: a verdict smuggling a kubectl line streams it commented out.
	sse := `data: {"result":{"kind":"message","role":"agent","parts":[{"kind":"data","data":{"verdict":{"status":"s","hypothesis":"h","killTest":"k","fix":"git revert HEAD\nkubectl delete ns demo-app"}}}]}}` + "\n\n" +
		`data: {"result":{"kind":"status-update","final":true,"status":{"state":"completed"}}}` + "\n\n"
	ts, _, _ := fakeKagent(t, sse)
	s := serverWithKagent(t, ts.URL, true)

	rec := httptest.NewRecorder()
	HandleAgentAsk(s, rec, askRequest(t))
	if !strings.Contains(rec.Body.String(), "not a git command") {
		t.Errorf("smuggled kubectl line must be flagged in the streamed verdict:\n%s", rec.Body.String())
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
