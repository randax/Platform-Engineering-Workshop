package kagent

// Hermetic tests for the A2A client: a scripted fake Kagent controller via
// httptest (prior art: internal/logs/logs_test.go). No cluster, no real Kagent,
// no LLM — the fake emits canned A2A JSON-RPC SSE frames and we assert the
// client parses them into the console's event vocabulary.

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"unicode/utf8"
)

// happyStream is the SSE an agent emits for a clean OOMKill investigation:
// two tool steps (call + result), a thinking message, a verdict, then a terminal
// status-update. Message/verdict/terminal frames use the documented,
// kind-discriminated A2A envelope; tool-call/tool-result are the modeled shape.
// Live kagent 0.9.12 emits NONE of these (see kagent0912Stream) — this stream is
// kept as the regression that the older/documented shapes still translate.
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
	_, err := c.Stream(t.Context(), Request{
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
	_, err := c.Stream(t.Context(), Request{Prompt: "x"}, func(Event) error { called = true; return nil })
	if err == nil {
		t.Fatal("unreachable agent must return an error")
	}
	if called {
		t.Error("emit must not be called when the agent is unreachable")
	}
}

func TestStreamUnmodeledFramesYieldNothing(t *testing.T) {
	// A stream of frames that carry nothing renderable — a Task, an unknown kind,
	// and an empty artifact — followed by a clean terminal. The client emits
	// nothing (no invented events) and returns cleanly, and the Stats it returns
	// let the handler say what it actually saw instead of guessing at a cause.
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, `data: {"result":{"kind":"task","id":"t1","status":{"state":"working"}}}`+"\n\n"+
			`data: {"result":{"kind":"whatever-comes-next","taskId":"t1"}}`+"\n\n"+
			`data: {"result":{"kind":"artifact-update","taskId":"t1","artifact":{"name":"x"}}}`+"\n\n"+
			`data: {"result":{"kind":"status-update","final":true,"status":{"state":"completed"}}}`+"\n\n")
	}))
	defer ts.Close()

	c := &Client{base: ts.URL, http: ts.Client()}
	n := 0
	stats, err := c.Stream(t.Context(), Request{Prompt: "x"}, func(Event) error { n++; return nil })
	if err != nil {
		t.Fatalf("stream: %v", err)
	}
	if n != 0 {
		t.Errorf("unmodeled frames must not produce events, got %d", n)
	}
	if stats.Frames != 4 || stats.Malformed != 0 {
		t.Errorf("stats = %+v, want 4 frames / 0 malformed", stats)
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
	_, err := c.Stream(t.Context(), Request{Prompt: "x"}, func(Event) error { n++; return nil })
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
	_, err := c.Stream(t.Context(), Request{Prompt: "x"}, func(Event) error { return nil })
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
	_, err := c.Stream(t.Context(), Request{Prompt: "x"}, func(e Event) error { got = append(got, e); return nil })
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
	_, err := c.Stream(t.Context(), Request{Prompt: "x"}, func(Event) error { return nil })
	if err == nil || !strings.Contains(err.Error(), "model backend unavailable") {
		t.Fatalf("agent error not surfaced: %v", err)
	}
}

// --- kagent 0.9.12, captured from the wire -----------------------------------
//
// The frames below are the REAL ones, captured on 2026-08-17 from the pinned
// kagent 0.9.12 in the workshop cluster (host Ollama, qwen3:4b) with
//
//	kubectl -n kagent port-forward svc/kagent-controller 18083:8083
//	curl -sN -X POST http://127.0.0.1:18083/api/a2a/kagent/k8s-agent/ \
//	  -H 'Content-Type: application/json' -H 'Accept: text/event-stream' \
//	  -d '{"jsonrpc":"2.0","id":"p","method":"message/stream","params":{"message":
//	      {"role":"user","contextId":"p","parts":[{"kind":"text","text":"…"}]}}}'
//
// Kept structurally verbatim (kind/role/parts/data/metadata paths, key order,
// the `kagent_adk_partial: null` and usage-metadata noise on one frame to prove
// unknown fields are tolerated); only the bulk of the repeated per-frame
// metadata is trimmed for readability. Everything the translator reads is
// untouched, so these are the regression fixture for "the Case file renders
// against the pinned kagent".
const (
	// Frame 0: the FIRST thing kagent sends is the attendee's own prompt echoed
	// back with role "user". It must not become a log line (and must not count as
	// a rendered event, or a failed run would look successful).
	k12Echo = `data: {"result":{"kind":"status-update","contextId":"p","final":false,"status":{"message":{"kind":"message","messageId":"","contextId":"p","parts":[{"kind":"text","text":"Use your tools to count the nodes in this cluster."}],"role":"user","taskId":"t"},"state":"submitted"},"taskId":"t"}}`

	// Frame 1: a bare working status — no message at all.
	k12Working = `data: {"result":{"kind":"status-update","contextId":"p","final":false,"status":{"state":"working"},"taskId":"t","metadata":{"kagent_app_name":"kagent__NS__k8s_agent","kagent_session_id":"p","kagent_user_id":"p"}}}`

	// Frame 2: a TOOL CALL — a data part, {args,id,name}, kagent_type=function_call.
	k12ToolCall = `data: {"result":{"kind":"status-update","contextId":"p","final":false,"status":{"message":{"kind":"message","messageId":"9c600f1e","contextId":"p","metadata":{"kagent_adk_partial":null,"kagent_author":"k8s_agent","kagent_usage_metadata":{"candidatesTokenCount":3311,"promptTokenCount":2384,"totalTokenCount":5695}},"parts":[{"kind":"data","data":{"args":{"all_namespaces":"false","resource_type":"node"},"id":"50ebbe97","name":"k8s_get_resources"},"metadata":{"kagent_type":"function_call"}}],"role":"agent","taskId":"t"},"state":"working"},"taskId":"t"}}`

	// Frame 3: the TOOL RESULT — same data-part shape, but with `response`
	// carrying an MCP-style {content:[{text,type}],isError} envelope. This
	// capture is a real tool FAILURE (the agent passed all_namespaces to a
	// cluster-scoped resource), which is exactly the texture module 10 wants.
	k12ToolResult = `data: {"result":{"kind":"status-update","contextId":"p","final":false,"status":{"message":{"kind":"message","messageId":"d75d4255","contextId":"p","parts":[{"kind":"data","data":{"id":"50ebbe97","name":"k8s_get_resources","response":{"content":[{"text":"[Kubernetes] get node -o wide failed: exit status 1","type":"text"}],"isError":true}},"metadata":{"kagent_type":"function_response"}}],"role":"agent","taskId":"t"},"state":"working"},"taskId":"t"}}`

	// Frame 4: NARRATION — a text part on an agent-role status-update message.
	k12Narration = `data: {"result":{"kind":"status-update","contextId":"p","final":false,"status":{"message":{"kind":"message","messageId":"f4d78ca4","contextId":"p","parts":[{"kind":"text","text":"The cluster currently has 0 nodes available."}],"role":"agent","taskId":"t"},"state":"working"},"taskId":"t"}}`

	// Frame 5: the FINAL ANSWER — an artifact-update, lastChunk. This capture's
	// answer ignores the requested Status/Hypothesis/Kill-test/Fix shape entirely
	// (a 4B local model often does), so it exercises the verbatim fallback.
	k12Artifact = `data: {"result":{"kind":"artifact-update","artifact":{"artifactId":"189849e6","parts":[{"kind":"text","text":"The cluster currently has 0 nodes available."}]},"contextId":"p","lastChunk":true,"taskId":"t"}}`

	// Frame 6: the terminus.
	k12Final = `data: {"result":{"kind":"status-update","contextId":"p","final":true,"status":{"state":"completed"},"taskId":"t"}}`
)

// kagent0912Stream is the captured run, in order, framed as SSE.
var kagent0912Stream = strings.Join([]string{
	k12Echo, k12Working, k12ToolCall, k12ToolResult, k12Narration, k12Artifact, k12Final,
}, "\n\n") + "\n\n"

// TestStreamKagent0912 is THE regression: a stream made only of status-update and
// artifact-update frames — no top-level `message`, no modeled `tool-call` — must
// translate into a full case file. Before the 2026-08-17 reconciliation every
// frame here fell through translate(), the handler saw zero events, and the
// browser got "the agent responded in a format this console doesn't recognize".
func TestStreamKagent0912(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, kagent0912Stream)
	}))
	defer ts.Close()

	c := &Client{base: ts.URL, http: ts.Client()}
	var got []Event
	stats, err := c.Stream(t.Context(), Request{Prompt: "count the nodes"}, func(e Event) error {
		got = append(got, e)
		return nil
	})
	if err != nil {
		t.Fatalf("stream: %v", err)
	}
	if stats.Frames != 7 {
		t.Errorf("stats.Frames = %d, want 7", stats.Frames)
	}

	wantKinds := []EventKind{KindToolCall, KindToolResult, KindMessage, KindVerdict}
	if len(got) != len(wantKinds) {
		t.Fatalf("got %d events, want %d: %+v", len(got), len(wantKinds), got)
	}
	for i, k := range wantKinds {
		if got[i].Kind != k {
			t.Errorf("event %d kind = %q, want %q", i, got[i].Kind, k)
		}
	}
	// The tool call: name out of data.name, arguments flattened to sorted k=v.
	if got[0].Tool != "k8s_get_resources" {
		t.Errorf("tool = %q, want k8s_get_resources", got[0].Tool)
	}
	if got[0].Args != "all_namespaces=false, resource_type=node" {
		t.Errorf("args = %q", got[0].Args)
	}
	// The tool result: the MCP envelope unwrapped, isError made visible, and a
	// one-line read derived from the output (kagent supplies no observation).
	if !strings.Contains(got[1].Output, "get node -o wide failed") {
		t.Errorf("tool result output = %q", got[1].Output)
	}
	if !strings.HasPrefix(got[1].Output, "tool error: ") {
		t.Errorf("isError must be visible in the output: %q", got[1].Output)
	}
	if !strings.Contains(got[1].Observation, "failed") {
		t.Errorf("observation should summarise the output, got %q", got[1].Observation)
	}
	// The narration.
	if got[2].Text != "The cluster currently has 0 nodes available." {
		t.Errorf("narration = %q", got[2].Text)
	}
	// The artifact: an answer with no recognisable section shape still fills the
	// panel verbatim — a plain answer beats an error card.
	v := got[3].Verdict
	if v == nil {
		t.Fatal("artifact-update must produce a verdict")
	}
	if v.Hypothesis != "The cluster currently has 0 nodes available." {
		t.Errorf("unstructured answer should land verbatim, got %q", v.Hypothesis)
	}
}

// TestStreamKagent0912EchoNotRendered pins the echoed prompt out of the log: a
// run that says nothing but the echo must still count as zero rendered events,
// or the handler's "nothing was readable" guard would never fire again.
func TestStreamKagent0912EchoNotRendered(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, k12Echo+"\n\n"+k12Working+"\n\n"+k12Final+"\n\n")
	}))
	defer ts.Close()

	c := &Client{base: ts.URL, http: ts.Client()}
	var got []Event
	stats, err := c.Stream(t.Context(), Request{Prompt: "x"}, func(e Event) error { got = append(got, e); return nil })
	if err != nil {
		t.Fatalf("stream: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("the echoed user prompt must not be rendered, got %+v", got)
	}
	if stats.Frames != 3 {
		t.Errorf("stats.Frames = %d, want 3", stats.Frames)
	}
}

// TestTranslateFrames is the table over frame shapes: what each one, alone,
// turns into. Cases marked (captured) are verbatim from the 0.9.12 capture; the
// rest are tolerance cases for shapes a beta upstream may well emit next.
func TestTranslateFrames(t *testing.T) {
	cases := []struct {
		name  string
		frame string
		want  []EventKind
		done  bool
		check func(*testing.T, []Event)
	}{{
		name:  "captured: echoed user prompt is not an event",
		frame: k12Echo,
	}, {
		name:  "captured: bare working status",
		frame: k12Working,
	}, {
		name:  "captured: tool call in a status-update data part",
		frame: k12ToolCall,
		want:  []EventKind{KindToolCall},
	}, {
		name:  "captured: tool result in a status-update data part",
		frame: k12ToolResult,
		want:  []EventKind{KindToolResult},
	}, {
		name:  "captured: narration in a status-update text part",
		frame: k12Narration,
		want:  []EventKind{KindMessage},
	}, {
		name:  "captured: final answer as an artifact-update",
		frame: k12Artifact,
		want:  []EventKind{KindVerdict},
	}, {
		name:  "captured: terminal status-update",
		frame: k12Final,
		done:  true,
	}, {
		name:  "tolerance: a data part with no kagent_type is read structurally",
		frame: `data: {"result":{"kind":"status-update","status":{"message":{"role":"agent","parts":[{"kind":"data","data":{"name":"k8s_get_pod_logs","args":{"namespace":"demo"}}}]}}}}`,
		want:  []EventKind{KindToolCall},
		check: func(t *testing.T, evs []Event) {
			if evs[0].Tool != "k8s_get_pod_logs" || evs[0].Args != "namespace=demo" {
				t.Errorf("got %+v", evs[0])
			}
		},
	}, {
		name:  "tolerance: kagent_type says response even with no response body",
		frame: `data: {"result":{"kind":"status-update","status":{"message":{"role":"agent","parts":[{"kind":"data","data":{"name":"k8s_get_resources"},"metadata":{"kagent_type":"function_response"}}]}}}}`,
		want:  []EventKind{KindToolResult},
	}, {
		name:  "tolerance: a response that is not the MCP envelope is shown raw",
		frame: `data: {"result":{"kind":"status-update","status":{"message":{"role":"agent","parts":[{"kind":"data","data":{"name":"t","response":{"rows":3,"ok":true}}}]}}}}`,
		want:  []EventKind{KindToolResult},
		check: func(t *testing.T, evs []Event) {
			if !strings.Contains(evs[0].Output, `"rows":3`) {
				t.Errorf("unknown response shape should degrade to raw JSON, got %q", evs[0].Output)
			}
		},
	}, {
		name:  "tolerance: several parts in one frame yield several events",
		frame: `data: {"result":{"kind":"status-update","status":{"message":{"role":"agent","parts":[{"kind":"data","data":{"name":"a"}},{"kind":"text","text":"thinking"}]}}}}`,
		want:  []EventKind{KindToolCall, KindMessage},
	}, {
		name:  "tolerance: a last word on the terminal frame is still shown",
		frame: `data: {"result":{"kind":"status-update","final":true,"status":{"state":"completed","message":{"role":"agent","parts":[{"kind":"text","text":"done"}]}}}}`,
		want:  []EventKind{KindMessage},
		done:  true,
	}, {
		name:  "tolerance: the modeled verdict data part still wins",
		frame: `data: {"result":{"kind":"status-update","status":{"message":{"role":"agent","parts":[{"kind":"data","data":{"verdict":{"status":"s","hypothesis":"h","killTest":"k","fix":"git push"}}}]}}}}`,
		want:  []EventKind{KindVerdict},
		check: func(t *testing.T, evs []Event) {
			if evs[0].Verdict == nil || evs[0].Verdict.Fix != "git push" {
				t.Errorf("got %+v", evs[0].Verdict)
			}
		},
	}, {
		name:  "kept: the documented top-level message",
		frame: `data: {"result":{"kind":"message","role":"agent","parts":[{"kind":"text","text":"hi"}]}}`,
		want:  []EventKind{KindMessage},
	}, {
		name:  "kept: the modeled tool-call",
		frame: `data: {"result":{"kind":"tool-call","tool":"k8s_get_resources","args":"pods -n demo"}}`,
		want:  []EventKind{KindToolCall},
	}, {
		name:  "kept: the modeled tool-result",
		frame: `data: {"result":{"kind":"tool-result","output":"o","observation":"obs"}}`,
		want:  []EventKind{KindToolResult},
		check: func(t *testing.T, evs []Event) {
			if evs[0].Observation != "obs" {
				t.Errorf("a supplied observation must be used verbatim, got %q", evs[0].Observation)
			}
		},
	}, {
		name:  "an artifact with no text produces nothing",
		frame: `data: {"result":{"kind":"artifact-update","artifact":{"parts":[{"kind":"text","text":"   "}]}}}`,
	}}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var env rpcEnvelope
			payload := strings.TrimPrefix(tc.frame, "data: ")
			if err := json.Unmarshal([]byte(payload), &env); err != nil {
				t.Fatalf("fixture is not valid JSON: %v", err)
			}
			evs, done := translate(env.Result)
			if done != tc.done {
				t.Errorf("done = %v, want %v", done, tc.done)
			}
			if len(evs) != len(tc.want) {
				t.Fatalf("got %d events %+v, want %d %v", len(evs), evs, len(tc.want), tc.want)
			}
			for i, k := range tc.want {
				if evs[i].Kind != k {
					t.Errorf("event %d kind = %q, want %q", i, evs[i].Kind, k)
				}
			}
			if tc.check != nil {
				tc.check(t, evs)
			}
		})
	}
}

// TestVerdictFromAnswer covers the final answer → panel mapping. The opening
// prompt asks for Status → Hypothesis → Kill-test → Fix; a local model produces
// a different flavour of markdown every run, and sometimes ignores the shape
// altogether. Never an error: worst case the answer is shown verbatim.
func TestVerdictFromAnswer(t *testing.T) {
	cases := []struct {
		name   string
		answer string
		want   Verdict
	}{{
		name: "plain colons",
		answer: "Status: Diagnosed — unverified\n" +
			"Hypothesis: PORT=8080-canary is not a number, so the server exits at startup.\n" +
			"Kill-test: kubectl -n demo logs deploy/demo-web --previous | tail -5\n" +
			"Fix: git revert HEAD\ngit push\n",
		want: Verdict{
			Status:     "Diagnosed — unverified",
			Hypothesis: "PORT=8080-canary is not a number, so the server exits at startup.",
			KillTest:   "kubectl -n demo logs deploy/demo-web --previous | tail -5",
			Fix:        "git revert HEAD\ngit push",
		},
	}, {
		name: "markdown bold and numbered, kill-test spelled differently",
		answer: "1. **Status:** CrashLoopBackOff\n2. **Hypothesis**: the memory limit is 48Mi\n" +
			"3. **KILL_TEST** — kubectl get pod -o jsonpath='{..reason}'\n4. **Fix:**\ngit revert HEAD\n",
		want: Verdict{
			Status:     "CrashLoopBackOff",
			Hypothesis: "the memory limit is 48Mi",
			KillTest:   "kubectl get pod -o jsonpath='{..reason}'",
			Fix:        "git revert HEAD",
		},
	}, {
		name: "markdown headings with the body on following lines, fences dropped",
		answer: "## Status\nDiagnosed\n\n## Hypothesis\nbad env var\n\n## Kill test\ncheck the logs\n\n## Fix\n" +
			"```sh\ngit revert HEAD\ngit push\n```\n",
		want: Verdict{
			Status:     "Diagnosed",
			Hypothesis: "bad env var",
			KillTest:   "check the logs",
			Fix:        "git revert HEAD\ngit push",
		},
	}, {
		name:   "no recognisable shape at all — shown verbatim, never an error",
		answer: "The cluster currently has 0 nodes available.",
		want:   Verdict{Hypothesis: "The cluster currently has 0 nodes available."},
	}, {
		name:   "preamble fills a missing hypothesis",
		answer: "The web container never starts.\n\nFix: git revert HEAD\n",
		want:   Verdict{Hypothesis: "The web container never starts.", Fix: "git revert HEAD"},
	}, {
		name:   "prose that merely starts with a keyword is not a heading",
		answer: "Fix the deployment by lowering its memory request, probably.",
		want:   Verdict{Hypothesis: "Fix the deployment by lowering its memory request, probably."},
	}, {
		// Verbatim from the first live render through the Console's own /agent/ask
		// against kagent 0.9.12 (qwen3:4b, 2026-08-17). The model wraps everything
		// in <response>…</response>; the closing tag used to land in the Fix block
		// and render as "⚠ not a git command — review before running: </response>".
		name: "live: the model's <response> wrapper is dropped, not fed to the Fix",
		answer: "<response>\nStatus: demo-web workload is unhealthy due to database dependencies failing.\n\n" +
			"Hypothesis: Webhook services are unreachable, causing database pods to fail readiness probes.\n\n" +
			"Kill-test: The service `webhook.knative-serving.svc` exists and is running.\n\n" +
			"Fix: \ngit checkout -b fix-webhook-services\ngit push origin fix-webhook-services\n</response>",
		want: Verdict{
			Status:     "demo-web workload is unhealthy due to database dependencies failing.",
			Hypothesis: "Webhook services are unreachable, causing database pods to fail readiness probes.",
			KillTest:   "The service `webhook.knative-serving.svc` exists and is running.",
			Fix:        "git checkout -b fix-webhook-services\ngit push origin fix-webhook-services",
		},
	}}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := verdictFromAnswer(tc.answer)
			if got == nil {
				t.Fatal("verdictFromAnswer returned nil for a non-empty answer")
			}
			if *got != tc.want {
				t.Errorf("got  %#v\nwant %#v", *got, tc.want)
			}
		})
	}

	if v := verdictFromAnswer("  \n\n "); v != nil {
		t.Errorf("a blank answer must yield no verdict, got %#v", v)
	}
}

// TestStreamKagent0912MidRunError pins the OTHER live failure mode seen on
// 2026-08-17: the controller gives up mid-run and sends a JSON-RPC error frame
// after a real tool call. The tool step already shown stays shown, and the
// failure is reported honestly rather than looking like a finished run.
func TestStreamKagent0912MidRunError(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, k12Echo+"\n\n"+k12ToolCall+"\n\n"+
			`data: {"error":{"code":-32603,"message":"SSE stream error: unexpected EOF"}}`+"\n\n")
	}))
	defer ts.Close()

	c := &Client{base: ts.URL, http: ts.Client()}
	var got []Event
	_, err := c.Stream(t.Context(), Request{Prompt: "x"}, func(e Event) error { got = append(got, e); return nil })
	if err == nil || !strings.Contains(err.Error(), "unexpected EOF") {
		t.Fatalf("a mid-run error frame must surface: %v", err)
	}
	if len(got) != 1 || got[0].Kind != KindToolCall {
		t.Errorf("events before the failure should still have been emitted, got %+v", got)
	}
}

// TestToolOutputTruncated bounds one tool result: a runaway tool must not push
// megabytes into the browser, and the cut must stay valid UTF-8.
func TestToolOutputTruncated(t *testing.T) {
	long := strings.Repeat("æ", maxToolOutput) // multi-byte, so the cut lands mid-rune
	raw, err := json.Marshal(map[string]any{"content": []map[string]string{{"text": long}}})
	if err != nil {
		t.Fatal(err)
	}
	out := toolOutput(raw)
	if !strings.HasSuffix(out, "…(truncated)") {
		t.Errorf("oversized output should be marked truncated, got %d bytes", len(out))
	}
	if !utf8.ValidString(out) {
		t.Error("truncation must cut on a rune boundary")
	}
	if len(out) > maxToolOutput+32 {
		t.Errorf("output not bounded: %d bytes", len(out))
	}
}
