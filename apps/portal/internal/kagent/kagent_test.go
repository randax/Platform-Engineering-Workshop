package kagent

// Hermetic tests for the A2A client: a scripted fake Kagent controller via
// httptest (prior art: internal/logs/logs_test.go). No cluster, no real Kagent,
// no LLM — the fake emits canned A2A JSON-RPC SSE frames and we assert the
// client parses them into the console's event vocabulary.

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// happyStream is the SSE an agent emits for a clean OOMKill investigation:
// two tool steps (call + result), a thinking message, a verdict, then done.
const happyStream = `data: {"result":{"type":"tool_call","tool":"k8s_get_resources","args":"pods -n demo-app"}}

data: {"result":{"type":"tool_result","output":"0/1 Running 7 restarts","observation":"7 restarts in 11 minutes"}}

data: {"result":{"type":"tool_call","tool":"k8s_describe_resource","args":"pod demo-app-x8k2p"}}

data: {"result":{"type":"tool_result","output":"Reason: OOMKilled\nLimits: memory 48Mi","observation":"OOMKilled and the limit is only 48Mi"}}

data: {"result":{"type":"message","text":"forming a hypothesis"}}

data: {"result":{"type":"verdict","verdict":{"status":"Diagnosed — unverified","hypothesis":"memory limit 48Mi is below the real working set","killTest":"kubectl -n demo-app get pod -o jsonpath='{..lastState.terminated.reason}'","fix":"git revert HEAD\ngit push"}}}

data: {"result":{"type":"done","final":true}}

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

func TestStreamUnreachable(t *testing.T) {
	// A base URL that refuses connections → a real, reported failure (the
	// browser's error state), never a silent empty stream.
	c := &Client{base: "http://127.0.0.1:1", http: &http.Client{Timeout: time.Second}}
	called := false
	err := c.Stream(t.Context(), Request{Prompt: "x"}, func(Event) error { called = true; return nil })
	if err == nil {
		t.Fatal("unreachable agent must return an error")
	}
	if called {
		t.Error("emit must not be called when the agent is unreachable")
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
