package kagent

// Hermetic tests for the A2A client: a scripted fake Kagent controller via
// httptest (prior art: internal/logs/logs_test.go). No cluster, no real Kagent,
// no LLM — the fake emits canned A2A JSON-RPC SSE frames and we assert the
// client parses them into the console's event vocabulary.

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// happyStream is the SSE an agent emits for a clean OOMKill investigation:
// two tool steps (call + result), a thinking message, a verdict, then a terminal
// status-update. Message/verdict/terminal frames use the documented,
// kind-discriminated A2A envelope; tool-call/tool-result are the modeled shape
// (reconcile against live kagent at rehearsal — see spec #133 rehearsal gates).
// The verdict rides an A2A message DataPart.
const happyStream = `data: {"result":{"kind":"tool-call","tool":"k8s_get_resources","args":"pods -n demo-app"}}

data: {"result":{"kind":"tool-result","output":"0/1 Running 7 restarts","observation":"7 restarts in 11 minutes"}}

data: {"result":{"kind":"tool-call","tool":"k8s_describe_resource","args":"pod demo-app-x8k2p"}}

data: {"result":{"kind":"tool-result","output":"Reason: OOMKilled\nLimits: memory 48Mi","observation":"OOMKilled and the limit is only 48Mi"}}

data: {"result":{"kind":"message","role":"agent","parts":[{"kind":"text","text":"forming a hypothesis"}]}}

data: {"result":{"kind":"message","role":"agent","parts":[{"kind":"data","data":{"verdict":{"status":"Diagnosed — unverified","hypothesis":"memory limit 48Mi is below the real working set","killTest":"kubectl -n demo-app get pod -o jsonpath='{..lastState.terminated.reason}'","fix":"git revert HEAD\ngit push"}}}]}}

data: {"result":{"kind":"status-update","final":true,"status":{"state":"completed"}}}

`

func TestStreamHappyPath(t *testing.T) {
	var gotUserID, gotMethod, gotBody string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotUserID = r.Header.Get("X-User-ID")
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		if r.URL.Path != "/api/a2a/kagent/k8s-agent/" {
			t.Errorf("unexpected A2A path %q", r.URL.Path)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, happyStream)
	}))
	defer ts.Close()

	c := &Client{base: ts.URL, http: ts.Client()}
	var got []Event
	err := c.Stream(t.Context(), Request{
		Namespace: "demo-app", Kind: "Application", Name: "demo-app",
		Prompt: "why is demo-app unhealthy?", UserID: "user-42", SessionID: "sess-1",
	}, func(e Event) error {
		got = append(got, e)
		return nil
	})
	if err != nil {
		t.Fatalf("stream: %v", err)
	}

	// The request the portal sent: POST, identity header, an A2A message/stream
	// carrying the composed prompt.
	if gotMethod != http.MethodPost {
		t.Errorf("method = %q, want POST", gotMethod)
	}
	if gotUserID != "user-42" {
		t.Errorf("X-User-ID = %q, want user-42", gotUserID)
	}
	for _, want := range []string{"message/stream", "why is demo-app unhealthy?"} {
		if !strings.Contains(gotBody, want) {
			t.Errorf("request body missing %q: %s", want, gotBody)
		}
	}

	// The events, in order, translated into the console vocabulary.
	wantKinds := []EventKind{KindToolCall, KindToolResult, KindToolCall, KindToolResult, KindMessage, KindVerdict}
	if len(got) != len(wantKinds) {
		t.Fatalf("got %d events, want %d: %+v", len(got), len(wantKinds), got)
	}
	for i, k := range wantKinds {
		if got[i].Kind != k {
			t.Errorf("event %d kind = %q, want %q", i, got[i].Kind, k)
		}
	}
	if got[0].Tool != "k8s_get_resources" || got[0].Args != "pods -n demo-app" {
		t.Errorf("tool_call fields wrong: %+v", got[0])
	}
	if got[1].Observation != "7 restarts in 11 minutes" {
		t.Errorf("tool_result observation wrong: %+v", got[1])
	}
	v := got[5].Verdict
	if v == nil {
		t.Fatal("verdict event carried no Verdict")
	}
	if !strings.Contains(v.Hypothesis, "48Mi") {
		t.Errorf("hypothesis wrong: %q", v.Hypothesis)
	}
	if !strings.Contains(v.Fix, "git revert HEAD") || !strings.Contains(v.Fix, "git push") {
		t.Errorf("fix should be copy-paste git commands: %q", v.Fix)
	}
}

// errRoundTripper is a deterministic failing transport — every request errors,
// so an "unreachable agent" is exercised with no real socket.
type errRoundTripper struct{}

func (errRoundTripper) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("dial refused (hermetic)")
}

func TestStreamUnreachable(t *testing.T) {
	// The transport always fails → a real, reported failure (the browser's error
	// state), never a silent empty stream.
	c := &Client{base: "http://kagent.invalid", http: &http.Client{Transport: errRoundTripper{}}}
	called := false
	err := c.Stream(t.Context(), Request{Prompt: "x"}, func(Event) error { called = true; return nil })
	if err == nil {
		t.Fatal("unreachable agent must return an error")
	}
	if called {
		t.Error("emit must not be called when the agent is unreachable")
	}
}

func TestStreamUnmodeledFramesYieldNothing(t *testing.T) {
	// A stream of real A2A kinds the console does not (yet) model — a Task and an
	// artifact-update — followed by a clean terminal. The client emits nothing
	// (no invented events) and returns cleanly; the handler turns "zero events"
	// into a visible error so the envelope mismatch can't hide as a silent
	// success.
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, `data: {"result":{"kind":"task","id":"t1","status":{"state":"working"}}}`+"\n\n"+
			`data: {"result":{"kind":"artifact-update","taskId":"t1","artifact":{"name":"x"}}}`+"\n\n"+
			`data: {"result":{"kind":"status-update","final":true,"status":{"state":"completed"}}}`+"\n\n")
	}))
	defer ts.Close()

	c := &Client{base: ts.URL, http: ts.Client()}
	n := 0
	err := c.Stream(t.Context(), Request{Prompt: "x"}, func(Event) error { n++; return nil })
	if err != nil {
		t.Fatalf("stream: %v", err)
	}
	if n != 0 {
		t.Errorf("unmodeled frames must not produce events, got %d", n)
	}
}

func TestStreamTruncatedBeforeFinal(t *testing.T) {
	// The stream ends after a real tool step but WITHOUT the terminal
	// status-update — a dropped connection. That must surface as an error, not a
	// clean end that looks like a finished investigation.
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, `data: {"result":{"kind":"tool-call","tool":"k8s_get_resources","args":"pods"}}`+"\n\n")
	}))
	defer ts.Close()

	c := &Client{base: ts.URL, http: ts.Client()}
	n := 0
	err := c.Stream(t.Context(), Request{Prompt: "x"}, func(Event) error { n++; return nil })
	if err == nil || !strings.Contains(err.Error(), "final status-update") {
		t.Fatalf("truncated stream must error on missing terminal: %v", err)
	}
	if n != 1 {
		t.Errorf("events before the truncation should still have been emitted, got %d", n)
	}
}

func TestStreamMalformedCountedInError(t *testing.T) {
	// A malformed frame is skipped but counted; if the stream then ends without a
	// terminal, the error names how many frames were lost.
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, `data: {not valid json`+"\n\n"+
			`data: {"result":{"kind":"message","role":"agent","parts":[{"kind":"text","text":"hi"}]}}`+"\n\n")
	}))
	defer ts.Close()

	c := &Client{base: ts.URL, http: ts.Client()}
	err := c.Stream(t.Context(), Request{Prompt: "x"}, func(Event) error { return nil })
	if err == nil || !strings.Contains(err.Error(), "1 malformed") {
		t.Fatalf("error should name the malformed-frame count: %v", err)
	}
}

func TestStreamOversizedLineSurvives(t *testing.T) {
	// A single line far larger than the old 1 MB scanner cap (a big tool output)
	// must not kill the stream.
	huge := strings.Repeat("x", 2<<20) // 2 MiB
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, `data: {"result":{"kind":"tool-result","output":"`+huge+`","observation":"huge but fine"}}`+"\n\n"+
			`data: {"result":{"kind":"status-update","final":true,"status":{"state":"completed"}}}`+"\n\n")
	}))
	defer ts.Close()

	c := &Client{base: ts.URL, http: ts.Client()}
	var got []Event
	err := c.Stream(t.Context(), Request{Prompt: "x"}, func(e Event) error { got = append(got, e); return nil })
	if err != nil {
		t.Fatalf("oversized line must not fail the stream: %v", err)
	}
	if len(got) != 1 || got[0].Observation != "huge but fine" {
		t.Fatalf("oversized tool-result not parsed: %+v", got)
	}
}

func TestStreamAgentError(t *testing.T) {
	// The agent answers, but the run fails (e.g. the model backend is down):
	// a JSON-RPC error frame must surface as an error.
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, `data: {"error":{"code":-32000,"message":"model backend unavailable"}}`+"\n\n")
	}))
	defer ts.Close()

	c := &Client{base: ts.URL, http: ts.Client()}
	err := c.Stream(t.Context(), Request{Prompt: "x"}, func(Event) error { return nil })
	if err == nil || !strings.Contains(err.Error(), "model backend unavailable") {
		t.Fatalf("agent error not surfaced: %v", err)
	}
}
