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

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
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
// config, defaulting to the in-cluster controller Service). The transport is
// wrapped with otelhttp so each investigation shows up as a client span and
// propagates trace context, like the other internal clients (see internal/kube).
func New(baseURL string) *Client {
	return NewWithHTTPClient(baseURL, &http.Client{
		// An investigation is a multi-step agent run; give it room, but never
		// hang a browser forever.
		Timeout:   2 * time.Minute,
		Transport: otelhttp.NewTransport(nil),
	})
}

// NewWithHTTPClient builds a client with a caller-supplied http.Client — the
// seam tests use to inject a deterministic (e.g. always-erroring) transport, so
// no test ever opens a real socket.
func NewWithHTTPClient(baseURL string, hc *http.Client) *Client {
	return &Client{base: strings.TrimSuffix(baseURL, "/"), http: hc}
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

// rpcResult is one A2A streaming result off the SSE stream. A2A results are
// kind-discriminated (Message / TaskStatusUpdateEvent / TaskArtifactUpdateEvent
// / Task). We align the `message` and terminal `status-update` frames to the
// documented A2A envelope — including the verdict, carried as a message DataPart
// — so we only have to reconcile against live kagent at rehearsal (see spec
// #133 rehearsal gates) how a *tool step* surfaces. The `tool-call` /
// `tool-result` kinds are the console's model of that and remain the
// contract of record for the seam until then.
type rpcResult struct {
	Kind string `json:"kind"` // A2A: message | status-update; modeled: tool-call | tool-result

	// A2A message
	Role  string    `json:"role"`
	Parts []a2aPart `json:"parts"`

	// A2A status-update: the documented terminal streaming signal
	Final bool `json:"final"`

	// Modeled tool step (reconcile against live kagent at rehearsal — see spec #133 rehearsal gates)
	Tool        string `json:"tool"`
	Args        string `json:"args"`
	Output      string `json:"output"`
	Observation string `json:"observation"`
}

// a2aPart is one part of an A2A message: a text part (agent narration) or a data
// part carrying the structured verdict.
type a2aPart struct {
	Kind string    `json:"kind"` // text | data
	Text string    `json:"text"`
	Data *partData `json:"data"`
}

type partData struct {
	Verdict *Verdict `json:"verdict"`
}

// parseSSE reads text/event-stream frames, JSON-decodes each data payload as a
// JSON-RPC envelope, translates it to a console Event and hands it to emit.
//
// It reads with a bufio.Reader (not a size-capped Scanner) so a single oversized
// line — a large tool output — can't kill the stream. Individually malformed
// JSON frames are skipped but counted. The agent's stream must end with the
// terminal status-update (final:true); reaching EOF before that is reported as
// an error (with the skipped-frame count), never a silent clean end — otherwise
// a truncated or mismatched stream would look like a complete investigation.
func parseSSE(r io.Reader, emit func(Event) error) error {
	br := bufio.NewReader(r)
	var data strings.Builder
	var sawFinal bool
	var malformed int

	// dispatch decodes + emits the accumulated frame; done is true once the
	// terminal status-update has been seen.
	dispatch := func() (done bool, err error) {
		if data.Len() == 0 {
			return false, nil
		}
		payload := data.String()
		data.Reset()
		var env rpcEnvelope
		if err := json.Unmarshal([]byte(payload), &env); err != nil {
			malformed++ // skip this frame, but remember we lost one
			return false, nil
		}
		if env.Error != nil {
			return false, fmt.Errorf("agent error: %s", env.Error.Message)
		}
		if env.Result == nil {
			return false, nil
		}
		ev, ok, d := translate(env.Result)
		if ok {
			if err := emit(ev); err != nil {
				return false, err
			}
		}
		if d {
			sawFinal = true
			return true, nil
		}
		return false, nil
	}

	for {
		line, readErr := br.ReadString('\n')
		trimmed := strings.TrimRight(line, "\r\n") // tolerate CRLF (proxy normalization)
		switch {
		case trimmed == "": // blank line terminates the current event
			done, err := dispatch()
			if err != nil {
				return err
			}
			if done {
				return nil
			}
		case strings.HasPrefix(trimmed, ":"): // SSE comment / heartbeat
		default:
			if v, ok := strings.CutPrefix(trimmed, "data:"); ok {
				if data.Len() > 0 {
					data.WriteByte('\n')
				}
				data.WriteString(strings.TrimPrefix(v, " "))
			}
			// event:/id: field lines are not needed — the payload carries its kind.
		}
		if readErr != nil {
			if readErr != io.EOF {
				return readErr
			}
			// Flush a trailing event that had no terminating blank line.
			done, err := dispatch()
			if err != nil {
				return err
			}
			if done || sawFinal {
				return nil
			}
			if malformed > 0 {
				return fmt.Errorf("unexpected EOF before final status-update (%d malformed frame(s) skipped)", malformed)
			}
			return errors.New("unexpected EOF before final status-update")
		}
	}
}

// translate maps one A2A result to a console Event. ok is false for frames that
// carry no user-visible event (a terminal status-update, an unrecognised kind);
// done signals the stream is complete.
func translate(r *rpcResult) (ev Event, ok, done bool) {
	switch r.Kind {
	case "message":
		// A2A message: a data part carries the structured verdict; otherwise the
		// text parts are agent narration.
		for _, p := range r.Parts {
			if p.Kind == "data" && p.Data != nil && p.Data.Verdict != nil {
				return Event{Kind: KindVerdict, Verdict: p.Data.Verdict}, true, false
			}
		}
		var text strings.Builder
		for _, p := range r.Parts {
			if p.Kind == "text" {
				text.WriteString(p.Text)
			}
		}
		if text.Len() > 0 {
			return Event{Kind: KindMessage, Text: text.String()}, true, false
		}
		return Event{}, false, false
	case "status-update":
		// The documented terminal streaming event ends the run.
		return Event{}, false, r.Final
	case "tool-call": // modeled (reconcile against live kagent at rehearsal — see spec #133 rehearsal gates)
		return Event{Kind: KindToolCall, Tool: r.Tool, Args: r.Args}, true, false
	case "tool-result": // modeled (reconcile against live kagent at rehearsal — see spec #133 rehearsal gates)
		return Event{Kind: KindToolResult, Output: r.Output, Observation: r.Observation}, true, false
	default:
		return Event{}, false, false
	}
}
