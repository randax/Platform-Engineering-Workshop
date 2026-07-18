package kagent

// Thin A2A client for the in-cluster Kagent controller — the console's tie-in
// to the day-2 troubleshooting agent (module 10). Twin in spirit to
// internal/logs and internal/metrics: one HTTP call to a documented endpoint,
// no SDK, no CDN. We hand-roll the A2A JSON-RPC + SSE transport rather than
// import the first-party Go client (github.com/kagent-dev/kagent/go/api/client),
// because that library drags in controller-runtime and the whole k8s.io tree —
// far too heavy for an offline-first single-binary console whose only need here
// is "open one streaming call and translate its events".
//
// A2A (https://github.com/a2aproject/A2A) is JSON-RPC 2.0: we POST a
// `message/stream` request to the agent's per-agent A2A path and read back an
// SSE stream of JSON-RPC result envelopes, each carrying one investigation
// event. We translate those into the console's own event vocabulary
// (tool_call / tool_result / message / verdict).

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// The built-in k8s troubleshooting agent (research/kagent-current-state §5):
// the A2A server lives at /api/a2a/{namespace}/{agent}/ on the controller.
const (
	AgentNamespace = "kagent"
	AgentName      = "k8s-agent"
)

// EventKind is the console's event vocabulary — the SSE event names the browser
// routes on (the split-view log vs. the Status→Hypothesis→Kill-test→Fix panel).
type EventKind string

const (
	KindToolCall   EventKind = "tool_call"
	KindToolResult EventKind = "tool_result"
	KindMessage    EventKind = "message"
	KindVerdict    EventKind = "verdict"
)

// Verdict is the agent's conclusion: a hypothesis, the one observation that
// would falsify it (the kill-test), and the fix as copy-paste git commands —
// never a mutating action (the agent is read-only, issue #126).
type Verdict struct {
	Status     string `json:"status"`
	Hypothesis string `json:"hypothesis"`
	KillTest   string `json:"killTest"`
	Fix        string `json:"fix"`
}

// Event is one thing that happened during the investigation.
type Event struct {
	Kind        EventKind
	Tool        string   // tool_call: the tool the agent invoked
	Args        string   // tool_call: its arguments, one line
	Output      string   // tool_result: what the tool returned
	Observation string   // tool_result: the agent's one-line read of it
	Text        string   // message: a plain agent message
	Verdict     *Verdict // verdict: the conclusion
}

// Request is one investigation: which resource, and the opening prompt the
// portal composed from that resource + its diagnostics rollup. UserID becomes
// the A2A X-User-ID (identity, authless in-cluster); SessionID scopes the
// conversation to one resource per browser session — the seam a later ticket
// (#140) reuses to continue the same conversation for follow-ups.
type Request struct {
	Namespace string
	Kind      string
	Name      string
	Prompt    string
	UserID    string
	SessionID string
}

type Client struct {
	base string
	http *http.Client
}

// New builds a client against the Kagent controller base URL (injected from
// config, defaulting to the in-cluster controller Service).
func New(baseURL string) *Client {
	return &Client{
		base: strings.TrimSuffix(baseURL, "/"),
		// An investigation is a multi-step agent run; give it room, but never
		// hang a browser forever.
		http: &http.Client{Timeout: 2 * time.Minute},
	}
}

// Stream opens an A2A message/stream against the k8s-agent and calls emit once
// per investigation event, in order, as they arrive. It returns nil on a clean
// end (a `done` event or EOF), or an error if the agent is unreachable or the
// stream fails — the caller turns that into the browser's readable failure
// state. If emit returns an error (e.g. the browser disconnected), Stream stops
// and returns it.
func (c *Client) Stream(ctx context.Context, req Request, emit func(Event) error) error {
	body, err := json.Marshal(rpcRequest(req))
	if err != nil {
		return err
	}
	url := c.base + "/api/a2a/" + AgentNamespace + "/" + AgentName + "/"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "text/event-stream")
	if req.UserID != "" {
		httpReq.Header.Set("X-User-ID", req.UserID)
	}

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return fmt.Errorf("reaching the agent: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("agent returned %s", resp.Status)
	}
	return parseSSE(resp.Body, emit)
}

// rpcRequest builds the A2A JSON-RPC message/stream envelope.
func rpcRequest(req Request) map[string]any {
	id := req.SessionID
	if id == "" {
		id = "investigation"
	}
	return map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  "message/stream",
		"params": map[string]any{
			"message": map[string]any{
				"role":      "user",
				"contextId": id,
				"parts":     []map[string]any{{"kind": "text", "text": req.Prompt}},
			},
		},
	}
}

// rpcEnvelope is one JSON-RPC response frame off the SSE stream.
type rpcEnvelope struct {
	Result *rpcResult `json:"result"`
	Error  *rpcError  `json:"error"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// rpcResult carries one investigation event. `type` discriminates; the rest are
// the payload. This is the console's mapping of the agent's A2A event stream —
// the exact upstream JSON is reconciled against the real controller at
// packaging time (issue #134); here it is the contract of record for the seam.
type rpcResult struct {
	Type        string   `json:"type"`
	Tool        string   `json:"tool"`
	Args        string   `json:"args"`
	Output      string   `json:"output"`
	Observation string   `json:"observation"`
	Text        string   `json:"text"`
	Final       bool     `json:"final"`
	Verdict     *Verdict `json:"verdict"`
}

// errDone is the sentinel a `done` frame raises to stop the scan cleanly.
var errDone = errors.New("done")

// parseSSE reads text/event-stream frames, JSON-decodes each data payload as a
// JSON-RPC envelope, translates it to a console Event and hands it to emit.
func parseSSE(r io.Reader, emit func(Event) error) error {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	var data strings.Builder
	dispatch := func() error {
		if data.Len() == 0 {
			return nil
		}
		payload := data.String()
		data.Reset()
		var env rpcEnvelope
		if err := json.Unmarshal([]byte(payload), &env); err != nil {
			return nil // skip a malformed frame rather than abort the whole run
		}
		if env.Error != nil {
			return fmt.Errorf("agent error: %s", env.Error.Message)
		}
		if env.Result == nil {
			return nil
		}
		ev, ok, done := translate(env.Result)
		if ok {
			if err := emit(ev); err != nil {
				return err
			}
		}
		if done {
			return errDone
		}
		return nil
	}
	for sc.Scan() {
		line := sc.Text()
		if line == "" { // blank line terminates an event
			if err := dispatch(); err != nil {
				if err == errDone {
					return nil
				}
				return err
			}
			continue
		}
		if strings.HasPrefix(line, ":") { // comment/heartbeat
			continue
		}
		if v, ok := strings.CutPrefix(line, "data:"); ok {
			if data.Len() > 0 {
				data.WriteByte('\n')
			}
			data.WriteString(strings.TrimPrefix(v, " "))
		}
		// event:/id: lines are not needed — the payload carries its own type.
	}
	if err := sc.Err(); err != nil {
		return err
	}
	// Flush a trailing event that had no terminating blank line.
	if err := dispatch(); err != nil && err != errDone {
		return err
	}
	return nil
}

// translate maps a JSON-RPC result to a console Event. ok is false for frames
// that carry no user-visible event (e.g. the terminal `done`); done signals the
// stream is complete.
func translate(r *rpcResult) (ev Event, ok, done bool) {
	switch r.Type {
	case "tool_call":
		return Event{Kind: KindToolCall, Tool: r.Tool, Args: r.Args}, true, false
	case "tool_result":
		return Event{Kind: KindToolResult, Output: r.Output, Observation: r.Observation}, true, false
	case "message":
		return Event{Kind: KindMessage, Text: r.Text}, true, false
	case "verdict":
		return Event{Kind: KindVerdict, Verdict: r.Verdict}, true, false
	case "done":
		return Event{}, false, true
	default:
		return Event{}, false, r.Final
	}
}
