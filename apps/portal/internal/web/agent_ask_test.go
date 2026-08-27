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
	"io"
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

// emptyStream is an answer made entirely of frames that carry nothing renderable
// (a Task, then a clean terminal) — what a future kagent whose frames have
// diverged again would look like from here.
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
		"composed Deployment is not Available", diag)
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

func TestAgentAskFollowupReusesSession(t *testing.T) {
	// A follow-up (a question on the same resource + browser session) must
	// continue the SAME Kagent session — not open a fresh one — and send just the
	// question, since the session already holds the opening context.
	var bodies []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		bodies = append(bodies, string(b))
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, investigationSSE)
	}))
	defer ts.Close()
	s := serverWithKagent(t, ts.URL, true)

	uid := strings.Repeat("a", 32) // a valid, stable browser identity
	call := func(question string) {
		p := map[string]string{"namespace": "demo-app", "kind": "Application", "name": "demo-app"}
		if question != "" {
			p["question"] = question
		}
		b, _ := json.Marshal(p)
		req := httptest.NewRequest(http.MethodPost, "/agent/ask", bytes.NewReader(b))
		req.AddCookie(&http.Cookie{Name: "cbx_uid", Value: uid})
		HandleAgentAsk(s, httptest.NewRecorder(), req)
	}
	call("")                             // the initial investigation
	call("why was the limit only 48Mi?") // a follow-up on the same resource

	if len(bodies) != 2 {
		t.Fatalf("want 2 upstream calls, got %d", len(bodies))
	}
	// Both A2A requests carry the SAME session id (uid:ns:kind:name) — the
	// follow-up continues the conversation rather than starting fresh.
	sess := uid + ":demo-app:Application:demo-app"
	for i, b := range bodies {
		if !strings.Contains(b, sess) {
			t.Errorf("call %d must reuse session %q:\n%s", i, sess, b)
		}
	}
	// The follow-up carries the question wrapped in minimal invariant framing
	// (resource identity + guardrails), but NOT the opening diagnostics rollup.
	if !strings.Contains(bodies[1], "why was the limit only 48Mi?") {
		t.Errorf("follow-up must carry the question:\n%s", bodies[1])
	}
	if !strings.Contains(bodies[1], "Continuing the read-only investigation") ||
		!strings.Contains(bodies[1], "demo-app") {
		t.Errorf("follow-up must carry the invariant framing (identity + guardrail):\n%s", bodies[1])
	}
	if strings.Contains(bodies[1], "You are a read-only Kubernetes troubleshooting agent") ||
		strings.Contains(bodies[1], "What the console's diagnostics panel already shows") {
		t.Errorf("follow-up must not re-send the opening diagnostics prompt:\n%s", bodies[1])
	}
	// ...but the initial call does send the opening prompt + its diagnostics rollup.
	if !strings.Contains(bodies[0], "You are a read-only Kubernetes troubleshooting agent") ||
		!strings.Contains(bodies[0], "What the console's diagnostics panel already shows") {
		t.Errorf("the initial call should send the opening prompt:\n%s", bodies[0])
	}
}

func TestAgentAskDistinctSessionsPerSurface(t *testing.T) {
	// Two surfaces investigating the SAME ns/name — an Application vs a platform
	// Component — must not share a Kagent session: the kind discriminates the id,
	// so a component whose namespace equals an Application's name can't collide
	// onto one conversation. The Component is also phrased honestly.
	var bodies []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		bodies = append(bodies, string(b))
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, investigationSSE)
	}))
	defer ts.Close()
	s := serverWithKagent(t, ts.URL, true)

	uid := strings.Repeat("a", 32)
	call := func(kind string) {
		b, _ := json.Marshal(map[string]string{"namespace": "demo", "kind": kind, "name": "demo"})
		req := httptest.NewRequest(http.MethodPost, "/agent/ask", bytes.NewReader(b))
		req.AddCookie(&http.Cookie{Name: "cbx_uid", Value: uid})
		HandleAgentAsk(s, httptest.NewRecorder(), req)
	}
	call("Application")
	call("Component")
	if len(bodies) != 2 {
		t.Fatalf("want 2 upstream calls, got %d", len(bodies))
	}
	appSess := uid + ":demo:Application:demo"
	compSess := uid + ":demo:Component:demo"
	if !strings.Contains(bodies[0], appSess) {
		t.Errorf("Application surface must use its own session %q:\n%s", appSess, bodies[0])
	}
	if !strings.Contains(bodies[1], compSess) || strings.Contains(bodies[1], appSess) {
		t.Errorf("Component surface must use a distinct session %q (no collision):\n%s", compSess, bodies[1])
	}
	if !strings.Contains(bodies[1], "platform component") || strings.Contains(bodies[1], "the Application") {
		t.Errorf("Component investigation must be phrased honestly (not 'the Application'):\n%s", bodies[1])
	}
}

func TestBuildInvestigationPromptKinds(t *testing.T) {
	app := buildInvestigationPrompt("Application", "demo", "demo-app", "", kube.Diagnostics{})
	if !strings.Contains(app, `the Application "demo-app" in namespace "demo"`) {
		t.Errorf("Application phrasing wrong:\n%s", app)
	}
	comp := buildInvestigationPrompt("Component", "demo", "demo", "", kube.Diagnostics{})
	if !strings.Contains(comp, `the workloads of platform component "demo" in namespace "demo"`) {
		t.Errorf("Component phrasing wrong:\n%s", comp)
	}
	if strings.Contains(comp, "the Application") {
		t.Errorf("Component prompt must not mislabel workloads as 'the Application':\n%s", comp)
	}
}

func TestAgentAskWhitespaceQuestionIsOpening(t *testing.T) {
	// A whitespace-only question is not a follow-up: it must be treated as an
	// opening request (the full prompt), never a bare, uncontextualised session.
	var bodies []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		bodies = append(bodies, string(b))
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, investigationSSE)
	}))
	defer ts.Close()
	s := serverWithKagent(t, ts.URL, true)

	b, _ := json.Marshal(map[string]string{
		"namespace": "demo-app", "kind": "Application", "name": "demo-app", "question": "   \t  ",
	})
	req := httptest.NewRequest(http.MethodPost, "/agent/ask", bytes.NewReader(b))
	HandleAgentAsk(s, httptest.NewRecorder(), req)

	if len(bodies) != 1 {
		t.Fatalf("want 1 upstream call, got %d", len(bodies))
	}
	if !strings.Contains(bodies[0], "You are a read-only Kubernetes troubleshooting agent") {
		t.Errorf("a whitespace-only question must behave as an opening request:\n%s", bodies[0])
	}
	if strings.Contains(bodies[0], "Follow-up question:") {
		t.Errorf("a whitespace-only question must not be treated as a follow-up:\n%s", bodies[0])
	}
}

func TestAgentAskFollowupErrorPath(t *testing.T) {
	// A follow-up whose agent is unreachable must surface an error event (which
	// the browser streams into the log and re-enables the input), never a silent
	// hang or a fresh verdict.
	s := serverWithKagent(t, "http://unused.invalid", true)
	s.Kagent = kagent.NewWithHTTPClient("http://kagent.invalid", &http.Client{Transport: errRoundTripper{}})

	body, _ := json.Marshal(map[string]string{
		"namespace": "demo", "kind": "Application", "name": "demo", "question": "why was it 48Mi?",
	})
	rec := httptest.NewRecorder()
	HandleAgentAsk(s, rec, httptest.NewRequest(http.MethodPost, "/agent/ask", bytes.NewReader(body)))

	b := rec.Body.String()
	if !strings.Contains(b, "event: error") {
		t.Errorf("a failed follow-up must surface an error event:\n%s", b)
	}
	if strings.Contains(b, "event: verdict") {
		t.Errorf("a failed follow-up must not render a verdict:\n%s", b)
	}
}

// TestCaseFileView pins the application-detail affordance: the investigation
// mount when the capability is available, and the locked affordance (with the
// unlock hint, and NO mount that could trigger a backend call) when it isn't.
func TestCaseFileView(t *testing.T) {
	tmpl, err := ParseTemplates(&Server{GrafanaURL: "http://grafana.cloudbox.k8s.test"})
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	base := sampleAppDetail() // an unhealthy, source-built app

	// Available: the split-view investigation mount + Open investigation button
	// + the follow-up input (#140).
	avail := base
	avail.CaseFile = caseFile{Show: true, Available: true, Kind: "Application", Namespace: "demo", Name: "api"}
	var on bytes.Buffer
	if err := tmpl.ExecuteTemplate(&on, "application-detail", avail); err != nil {
		t.Fatalf("render available: %v", err)
	}
	h := on.String()
	for _, want := range []string{"Case file", `id="case-file"`, `data-kind="Application"`, "Open investigation", "Kill-test", `id="cf-followup"`} {
		if !strings.Contains(h, want) {
			t.Errorf("available Case file missing %q", want)
		}
	}

	// Absent: the locked affordance with an unlock hint, and no mount.
	locked := base
	locked.CaseFile = caseFile{Show: true, Available: false, Kind: "Application", Namespace: "demo", Name: "api"}
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

// kagent0912SSE is the stream the PINNED kagent 0.9.12 actually sends, captured
// from the wire on 2026-08-17 (see internal/kagent/kagent_test.go for the exact
// capture command and the per-frame notes). Structurally verbatim; the repeated
// per-frame metadata is trimmed. Note what is NOT here: no top-level `message`
// frame and no `tool-call`/`tool-result` kind. Everything rides `status-update`,
// and the answer arrives as an `artifact-update`.
const kagent0912SSE = `data: {"result":{"kind":"status-update","final":false,"status":{"message":{"kind":"message","parts":[{"kind":"text","text":"You are a read-only Kubernetes troubleshooting agent. Investigate…"}],"role":"user","taskId":"t"},"state":"submitted"},"taskId":"t"}}

data: {"result":{"kind":"status-update","final":false,"status":{"state":"working"},"taskId":"t"}}

data: {"result":{"kind":"status-update","final":false,"status":{"message":{"kind":"message","parts":[{"kind":"data","data":{"args":{"namespace":"demo-app","resource_name":"demo-app","resource_type":"Deployment"},"id":"c1","name":"k8s_describe_resource"},"metadata":{"kagent_type":"function_call"}}],"role":"agent","taskId":"t"},"state":"working"},"taskId":"t"}}

data: {"result":{"kind":"status-update","final":false,"status":{"message":{"kind":"message","parts":[{"kind":"data","data":{"id":"c1","name":"k8s_describe_resource","response":{"content":[{"text":"Name: demo-app\nReason: OOMKilled\nLimits: memory 48Mi","type":"text"}],"isError":false}},"metadata":{"kagent_type":"function_response"}}],"role":"agent","taskId":"t"},"state":"working"},"taskId":"t"}}

data: {"result":{"kind":"status-update","final":false,"status":{"message":{"kind":"message","parts":[{"kind":"text","text":"The container was OOMKilled; the limit looks too low."}],"role":"agent","taskId":"t"},"state":"working"},"taskId":"t"}}

data: {"result":{"kind":"artifact-update","artifact":{"artifactId":"a1","parts":[{"kind":"text","text":"**Status:** Diagnosed — unverified\n\n**Hypothesis:** the memory limit 48Mi is below the real working set\n\n**Kill-test:** kubectl -n demo-app get pod -o jsonpath='{..lastState.terminated.reason}'\n\n**Fix:**\ngit revert HEAD\ngit push"}]},"lastChunk":true,"taskId":"t"}}

data: {"result":{"kind":"status-update","final":true,"status":{"state":"completed"},"taskId":"t"}}

`

// TestAgentAskRendersKagent0912Stream is THE regression for the bug the
// 2026-08-17 rehearsal found: against the pinned kagent, every frame fell
// through translate(), emitted stayed 0, and the browser got
// "the agent responded in a format this console doesn't recognize. Check that
// your kagent version matches the workshop pin." — while the agent run had
// SUCCEEDED. A status-update-only stream must render a case file, not an error.
func TestAgentAskRendersKagent0912Stream(t *testing.T) {
	ts, calls, _ := fakeKagent(t, kagent0912SSE)
	s := serverWithKagent(t, ts.URL, true)

	rec := httptest.NewRecorder()
	HandleAgentAsk(s, rec, askRequest(t))

	body := rec.Body.String()
	if *calls != 1 {
		t.Errorf("kagent called %d times, want 1", *calls)
	}
	if strings.Contains(body, "event: error") {
		t.Errorf("a successful kagent 0.9.12 run must not render an error:\n%s", body)
	}
	indexOrder(t, body,
		"event: tool_call",
		"event: tool_result",
		"event: message",
		"event: verdict",
		"event: done",
	)
	for _, want := range []string{
		"k8s_describe_resource",       // the tool, out of data.name
		"namespace=demo-app",          // its args, flattened
		"Name: demo-app",              // the tool output, unwrapped from the MCP envelope
		"The container was OOMKilled", // the narration, from a text part
		"Diagnosed — unverified",      // Status, parsed out of the artifact
		"48Mi",                        // Hypothesis
		"kubectl -n demo-app get pod", // Kill-test
		"git revert HEAD",             // Fix — copy-paste git
	} {
		if !strings.Contains(body, want) {
			t.Errorf("stream missing %q:\n%s", want, body)
		}
	}
	// The echoed prompt (frame 0, role "user") must never appear as a log line.
	if strings.Contains(body, "You are a read-only Kubernetes troubleshooting agent") {
		t.Errorf("the echoed user prompt must not be rendered into the log:\n%s", body)
	}
	// Still read-only: no mutating affordance anywhere in the stream.
	for _, forbidden := range []string{"hx-post", "hx-delete", "<button", "<form", "kubectl apply"} {
		if strings.Contains(body, forbidden) {
			t.Errorf("case file must not offer a mutating action, found %q", forbidden)
		}
	}
}

// TestAgentAskUnstructuredAnswerDegrades: kagent answers, but the model ignores
// the requested Status/Hypothesis/Kill-test/Fix shape (module 10's first beat, a
// small local model). The console must show the plain answer — a workshop is
// better served by a plain answer than an error card.
func TestAgentAskUnstructuredAnswerDegrades(t *testing.T) {
	sse := `data: {"result":{"kind":"artifact-update","artifact":{"parts":[{"kind":"text","text":"The pods are crashing because the image tag is wrong."}]},"lastChunk":true}}` + "\n\n" +
		`data: {"result":{"kind":"status-update","final":true,"status":{"state":"completed"}}}` + "\n\n"
	ts, _, _ := fakeKagent(t, sse)
	s := serverWithKagent(t, ts.URL, true)

	rec := httptest.NewRecorder()
	HandleAgentAsk(s, rec, askRequest(t))

	body := rec.Body.String()
	if strings.Contains(body, "event: error") {
		t.Errorf("an unstructured but real answer must not be an error:\n%s", body)
	}
	if !strings.Contains(body, "the image tag is wrong") {
		t.Errorf("the plain answer must still reach the panel:\n%s", body)
	}
	if !strings.Contains(body, "event: done") {
		t.Errorf("a run that produced an answer is done:\n%s", body)
	}
}

// TestNoEventsMessageIsObservable pins the wording of the zero-event error. The
// old text blamed the attendee's kagent version for a run that had succeeded,
// which cost a rehearsal an afternoon; the replacement may only state what was
// seen on the wire and where the truth is.
func TestNoEventsMessageIsObservable(t *testing.T) {
	cases := []struct {
		name  string
		stats kagent.Stats
		want  []string
	}{
		{"frames but nothing readable", kagent.Stats{Frames: 7}, []string{"7 frame", "completed", "kubectl -n kagent logs"}},
		{"nothing at all", kagent.Stats{}, []string{"without sending a single frame", "kubectl -n kagent logs"}},
		{"only malformed", kagent.Stats{Malformed: 3}, []string{"3 frame", "readable JSON"}},
		{"frames plus malformed", kagent.Stats{Frames: 2, Malformed: 1}, []string{"2 frame", "A further 1 frame"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := noEventsMessage(tc.stats)
			for _, w := range tc.want {
				if !strings.Contains(got, w) {
					t.Errorf("message %q missing %q", got, w)
				}
			}
			// Never send the attendee after a version pin they did not get wrong.
			for _, forbidden := range []string{"workshop pin", "version matches"} {
				if strings.Contains(got, forbidden) {
					t.Errorf("message must not blame the version pin: %q", got)
				}
			}
		})
	}
}

// TestAgentAskFollowupDoesNotDoubleTheAnswer: kagent sends its final answer
// twice — once as narration, once as the artifact. The client routes a
// follow-up's verdict into the LOG, where the narration already is (case-file.js),
// so the second copy would appear verbatim twice in one pane. Observed on a live
// follow-up against kagent 0.9.12 on 2026-08-17.
func TestAgentAskFollowupDoesNotDoubleTheAnswer(t *testing.T) {
	// Narration and artifact carry the identical text, as kagent really does.
	const answer = "Two pods are Completed, which is normal for jobs."
	sse := `data: {"result":{"kind":"status-update","status":{"message":{"role":"agent","parts":[{"kind":"text","text":"` + answer + `"}]}}}}` + "\n\n" +
		`data: {"result":{"kind":"artifact-update","artifact":{"parts":[{"kind":"text","text":"` + answer + `"}]},"lastChunk":true}}` + "\n\n" +
		`data: {"result":{"kind":"status-update","final":true,"status":{"state":"completed"}}}` + "\n\n"

	ask := func(question string) string {
		ts, _, _ := fakeKagent(t, sse)
		s := serverWithKagent(t, ts.URL, true)
		payload := map[string]string{"namespace": "demo-app", "kind": "Application", "name": "demo-app"}
		if question != "" {
			payload["question"] = question
		}
		b, _ := json.Marshal(payload)
		rec := httptest.NewRecorder()
		HandleAgentAsk(s, rec, httptest.NewRequest(http.MethodPost, "/agent/ask", bytes.NewReader(b)))
		return rec.Body.String()
	}

	// A follow-up: the answer streams into the log once, and no verdict repeats it.
	follow := ask("which pods are not Running?")
	if n := strings.Count(follow, answer); n != 1 {
		t.Errorf("a follow-up must show its answer once, got %d copies:\n%s", n, follow)
	}
	if strings.Contains(follow, "event: verdict") {
		t.Errorf("a follow-up whose answer already streamed must not repeat it as a verdict:\n%s", follow)
	}
	if !strings.Contains(follow, "event: done") {
		t.Errorf("the follow-up still completes:\n%s", follow)
	}

	// The OPENING investigation keeps the verdict: log and panel are different
	// panes, and the panel is the whole point of the Case file.
	open := ask("")
	if !strings.Contains(open, "event: verdict") {
		t.Errorf("the opening investigation must still fill the panel:\n%s", open)
	}
}

// The opening prompt must not assert a fault it has no evidence for. The
// investigation is now reachable on a component that looks fine — module 10's
// third scenario is a bad release whose pods all come up Running — and telling
// a 1.7B local model "explain why it is unhealthy" about a healthy namespace is
// how you get a confidently invented outage, in the one module whose lesson is
// that you must verify what the agent says.
func TestBuildInvestigationPromptDoesNotAssumeAFault(t *testing.T) {
	clean := buildInvestigationPrompt("Component", "demo", "demo", "", kube.Diagnostics{})
	if strings.Contains(clean, "explain why it is unhealthy") {
		t.Errorf("prompt asserts a fault with no evidence for one:\n%s", clean)
	}
	for _, want := range []string{
		"Do not assume there is a fault", // the guardrail
		"if the workloads are healthy, say so",
		"read-only", "git", // the standing guardrails survive
	} {
		if !strings.Contains(clean, want) {
			t.Errorf("evidence-free prompt missing %q:\n%s", want, clean)
		}
	}

	// With evidence, it still says the thing plainly.
	troubled := buildInvestigationPrompt("Component", "demo", "demo", "", kube.Diagnostics{
		PodTroubles: []kube.PodTrouble{{Pod: "demo-web-69dfd9d57c-zm6v2", Container: "web", Reason: "CrashLoopBackOff"}},
	})
	if !strings.Contains(troubled, "explain why it is unhealthy") {
		t.Errorf("prompt must name the fault when there IS one:\n%s", troubled)
	}
	if strings.Contains(troubled, "Do not assume there is a fault") {
		t.Errorf("evidence present, so the no-fault framing must not appear:\n%s", troubled)
	}
	// A warning event alone is evidence enough.
	warned := buildInvestigationPrompt("Component", "demo", "demo", "", kube.Diagnostics{
		Warnings: []kube.Event{{Reason: "FailedCreatePodSandBox", Message: "container init was OOM-killed"}},
	})
	if !strings.Contains(warned, "explain why it is unhealthy") {
		t.Errorf("a Warning event is evidence:\n%s", warned)
	}
}
