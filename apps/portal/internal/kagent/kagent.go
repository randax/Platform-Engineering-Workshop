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
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

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
	Kind   EventKind
	Tool   string // tool_call: the tool the agent invoked
	Args   string // tool_call: its arguments, one line
	Output string // tool_result: what the tool returned (truncated at maxToolOutput)
	// tool_result: the one-line read of the output. Kagent hands us the raw tool
	// response and narrates separately, so for its frames this is a summary we
	// derive from the output itself (see summarize) rather than the agent's own
	// words; the modeled `tool-result` frame supplies it directly.
	Observation string
	Text        string   // message: a plain agent message
	Verdict     *Verdict // verdict: the conclusion
}

// Stats is what the stream looked like on the wire: the observable facts a
// caller needs to explain a run that produced no events without having to guess
// at a cause (a version mismatch, say). Frames counts SSE data frames that
// decoded as a JSON-RPC envelope; Malformed counts frames that did not decode.
type Stats struct {
	Frames    int
	Malformed int
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
		// An investigation is a multi-step agent run; give it room, but never hang
		// a browser forever. Measured on the workshop's own pinned setup
		// (kagent 0.9.12, host Ollama, qwen3:4b, 2026-08-17): a two-tool-call run
		// took 2 m 54 s wall clock, which the previous 2-minute cap cut off before
		// the answer arrived. The attendee is not staring at a spinner — the
		// tool-call log streams as it happens — so the cap exists only to stop a
		// wedged run from holding a connection forever.
		Timeout:   6 * time.Minute,
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
// and returns it. The returned Stats describes the stream itself, so a caller
// facing zero events can say what it actually saw.
func (c *Client) Stream(ctx context.Context, req Request, emit func(Event) error) (Stats, error) {
	body, err := json.Marshal(rpcRequest(req))
	if err != nil {
		return Stats{}, err
	}
	url := c.base + "/api/a2a/" + AgentNamespace + "/" + AgentName + "/"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return Stats{}, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "text/event-stream")
	if req.UserID != "" {
		httpReq.Header.Set("X-User-ID", req.UserID)
	}

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return Stats{}, fmt.Errorf("reaching the agent: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return Stats{}, fmt.Errorf("agent returned %s", resp.Status)
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
// / Task).
//
// RECONCILED against live kagent 0.9.12 on 2026-08-17 (this is the rehearsal
// gate the previous version of this comment pointed at, and it moved the
// goalposts). What kagent actually emits is NOT a top-level `message` or a
// modeled `tool-call`; every interesting thing rides a `status-update`, and the
// final answer arrives as an `artifact-update`:
//
//	status-update · status.message.parts[].kind = "data",
//	    data = {name, args, id}                        ← tool call
//	    (part metadata.kagent_type = "function_call")
//	status-update · data = {name, id, response:{content:[{text}],isError}}
//	                                                   ← tool result
//	    (part metadata.kagent_type = "function_response")
//	status-update · status.message.parts[].kind = "text"   ← narration
//	    (status.message.role = "agent"; the FIRST frame echoes the prompt
//	     back with role = "user" — never narration, so we skip it)
//	artifact-update · artifact.parts[].text            ← the final answer
//	status-update · final = true                       ← terminus
//
// We keep the top-level `message` / `tool-call` / `tool-result` handling as well:
// this is a beta upstream whose frames have already changed once, so an older or
// newer kagent that emits the documented/modeled shapes still renders. Parsing
// is deliberately tolerant — structure decides, `kagent_type` only disambiguates
// — rather than a hard schema that breaks on the next release.
type rpcResult struct {
	Kind string `json:"kind"` // A2A: message | status-update | artifact-update; modeled: tool-call | tool-result

	// A2A message (top level)
	Role  string    `json:"role"`
	Parts []a2aPart `json:"parts"`

	// A2A status-update: the terminal streaming signal, and — as kagent uses it —
	// the carrier for every tool step and every line of narration.
	Final  bool       `json:"final"`
	Status *a2aStatus `json:"status"`

	// A2A artifact-update: kagent's final answer.
	Artifact *a2aArtifact `json:"artifact"`

	// Modeled tool step: kept for a kagent that emits it (see the note above).
	Tool        string `json:"tool"`
	Args        string `json:"args"`
	Output      string `json:"output"`
	Observation string `json:"observation"`
}

// a2aStatus is the status of a status-update; its optional message is where
// kagent puts tool steps and narration.
type a2aStatus struct {
	State   string      `json:"state"` // submitted | working | completed | failed
	Message *a2aMessage `json:"message"`
}

type a2aMessage struct {
	Role  string    `json:"role"` // user (the echoed prompt) | agent
	Parts []a2aPart `json:"parts"`
}

type a2aArtifact struct {
	Parts []a2aPart `json:"parts"`
}

// a2aPart is one part of an A2A message: a text part (narration, or the final
// answer on an artifact) or a data part. Data is kept raw and decoded tolerantly
// (see dataPartEvent) because its payload differs between the console's modeled
// verdict and kagent's own tool-step shapes.
type a2aPart struct {
	Kind     string          `json:"kind"` // text | data
	Text     string          `json:"text"`
	Data     json.RawMessage `json:"data"`
	Metadata partMetadata    `json:"metadata"`
}

// partMetadata is the only part-level metadata we read: kagent's own label for
// what a data part is. It is a hint, never a requirement.
type partMetadata struct {
	KagentType string `json:"kagent_type"` // function_call | function_response
}

// partData is every data-part payload we know how to read, in one tolerant
// struct: the console's modeled verdict, or kagent's tool call / tool result.
// A tool call and its result are told apart by whether `response` is present.
type partData struct {
	Verdict *Verdict `json:"verdict"`

	Name     string          `json:"name"`
	ID       string          `json:"id"`
	Args     json.RawMessage `json:"args"`
	Response json.RawMessage `json:"response"`
}

// toolResponse is the MCP-style envelope kagent's tools return. Anything that
// doesn't fit is rendered as its raw JSON instead of being dropped.
type toolResponse struct {
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
	IsError bool `json:"isError"`
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
func parseSSE(r io.Reader, emit func(Event) error) (Stats, error) {
	br := bufio.NewReader(r)
	var data strings.Builder
	var sawFinal bool
	var stats Stats

	// dispatch decodes + emits the accumulated frame; done is true once the
	// terminal status-update has been seen. One frame can carry several parts, so
	// it can yield several events.
	dispatch := func() (done bool, err error) {
		if data.Len() == 0 {
			return false, nil
		}
		payload := data.String()
		data.Reset()
		var env rpcEnvelope
		if err := json.Unmarshal([]byte(payload), &env); err != nil {
			stats.Malformed++ // skip this frame, but remember we lost one
			return false, nil
		}
		stats.Frames++
		if env.Error != nil {
			return false, fmt.Errorf("agent error: %s", env.Error.Message)
		}
		if env.Result == nil {
			return false, nil
		}
		evs, d := translate(env.Result)
		for _, ev := range evs {
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
				return stats, err
			}
			if done {
				return stats, nil
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
				return stats, readErr
			}
			// Flush a trailing event that had no terminating blank line.
			done, err := dispatch()
			if err != nil {
				return stats, err
			}
			if done || sawFinal {
				return stats, nil
			}
			if stats.Malformed > 0 {
				return stats, fmt.Errorf("unexpected EOF before final status-update (%d malformed frame(s) skipped)", stats.Malformed)
			}
			return stats, errors.New("unexpected EOF before final status-update")
		}
	}
}

// translate maps one A2A result to zero or more console Events (a frame can
// carry several parts). done signals the stream is complete.
func translate(r *rpcResult) (evs []Event, done bool) {
	switch r.Kind {
	case "message":
		// A2A message at the top level: its parts are narration and/or data.
		return partEvents(r.Parts, r.Role), false
	case "status-update":
		// Kagent's workhorse frame: the tool steps and the narration ride here,
		// on status.message.parts. `final` still ends the run — and a frame can be
		// both (a last word plus the terminus), so translate the parts either way.
		if r.Status != nil && r.Status.Message != nil {
			evs = partEvents(r.Status.Message.Parts, r.Status.Message.Role)
		}
		return evs, r.Final
	case "artifact-update":
		// Kagent's final answer. The prompt asks for Status → Hypothesis →
		// Kill-test → Fix, so we parse those out for the side panel; an answer
		// that ignores the shape still lands there verbatim (a plain answer beats
		// an error card).
		if r.Artifact == nil {
			return nil, false
		}
		var text strings.Builder
		for _, p := range r.Artifact.Parts {
			if p.Kind == "data" {
				// An artifact could equally carry the structured verdict directly.
				if ev, ok := dataPartEvent(p); ok {
					evs = append(evs, ev)
				}
				continue
			}
			text.WriteString(p.Text)
		}
		if v := verdictFromAnswer(text.String()); v != nil {
			evs = append(evs, Event{Kind: KindVerdict, Verdict: v})
		}
		return evs, false
	case "tool-call": // the modeled shape — kept for a kagent that emits it
		return []Event{{Kind: KindToolCall, Tool: r.Tool, Args: r.Args}}, false
	case "tool-result": // the modeled shape — kept for a kagent that emits it
		return []Event{{Kind: KindToolResult, Output: r.Output, Observation: r.Observation}}, false
	default:
		return nil, false
	}
}

// partEvents translates the parts of one A2A message. role guards narration: the
// first frame of a kagent stream echoes the attendee's own prompt back with
// role "user", which is not something the agent said and must not appear in the
// investigation log (nor count as a rendered event).
func partEvents(parts []a2aPart, role string) []Event {
	var evs []Event
	var text strings.Builder
	for _, p := range parts {
		switch p.Kind {
		case "data":
			if ev, ok := dataPartEvent(p); ok {
				evs = append(evs, ev)
			}
		default: // "text", or a part that omits its kind but carries text
			text.WriteString(p.Text)
		}
	}
	if s := text.String(); strings.TrimSpace(s) != "" && role != "user" {
		evs = append(evs, Event{Kind: KindMessage, Text: s})
	}
	return evs
}

// dataPartEvent reads one data part. Three payloads are recognised, in order of
// how specific they are: the console's modeled verdict, a tool RESULT (it has a
// `response`), and a tool CALL (it names a tool and has no response). Kagent's
// own `kagent_type` label is used only to break a tie, so a release that renames
// or drops it still works.
func dataPartEvent(p a2aPart) (Event, bool) {
	if len(p.Data) == 0 {
		return Event{}, false
	}
	var d partData
	if err := json.Unmarshal(p.Data, &d); err != nil {
		return Event{}, false
	}
	if d.Verdict != nil {
		return Event{Kind: KindVerdict, Verdict: d.Verdict}, true
	}
	hasResponse := len(d.Response) > 0 && string(d.Response) != "null"
	if hasResponse || p.Metadata.KagentType == "function_response" {
		out := toolOutput(d.Response)
		return Event{Kind: KindToolResult, Output: out, Observation: summarize(d.Name, out)}, true
	}
	if d.Name != "" {
		return Event{Kind: KindToolCall, Tool: d.Name, Args: formatArgs(d.Args)}, true
	}
	return Event{}, false
}

// maxToolOutput bounds what one tool result contributes to the page. A
// `describe` of a busy Deployment is already kilobytes; a runaway tool must not
// be able to push megabytes into the browser.
const maxToolOutput = 4 << 10

// toolOutput flattens a tool response into text. The MCP-style
// {content:[{text}],isError} envelope is unwrapped; anything else is rendered as
// its own JSON rather than dropped, so an upstream change degrades to something
// readable instead of a blank line.
func toolOutput(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var resp toolResponse
	var b strings.Builder
	if err := json.Unmarshal(raw, &resp); err == nil && len(resp.Content) > 0 {
		if resp.IsError {
			b.WriteString("tool error: ")
		}
		for i, c := range resp.Content {
			if i > 0 {
				b.WriteByte('\n')
			}
			b.WriteString(c.Text)
		}
	} else {
		b.Write(raw)
	}
	return truncate(b.String(), maxToolOutput)
}

// summarize is the one-line read of a tool result the log shows. Kagent narrates
// separately, so there is no agent-supplied observation to use: we state what is
// actually observable — the first line of the output and how much more there is.
func summarize(tool, out string) string {
	out = strings.TrimSpace(out)
	if out == "" {
		if tool != "" {
			return tool + " returned nothing"
		}
		return "returned nothing"
	}
	lines := strings.Split(out, "\n")
	first := strings.TrimSpace(lines[0])
	// Skip leading blanks so the summary isn't an empty string.
	for i := 1; i < len(lines) && first == ""; i++ {
		first = strings.TrimSpace(lines[i])
	}
	first = truncate(first, 160)
	if n := len(lines) - 1; n > 0 {
		return fmt.Sprintf("%s  (+%d more lines)", first, n)
	}
	return first
}

// formatArgs renders a tool call's arguments on one line. An object becomes
// sorted `key=value` pairs (readable in the log); anything else falls back to its
// compact JSON.
func formatArgs(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err != nil {
		return truncate(compactJSON(raw), 400)
	}
	keys := make([]string, 0, len(obj))
	for k := range obj {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	pairs := make([]string, 0, len(keys))
	for _, k := range keys {
		pairs = append(pairs, k+"="+scalarString(obj[k]))
	}
	return truncate(strings.Join(pairs, ", "), 400)
}

// scalarString renders one argument value: strings bare, everything else as JSON.
func scalarString(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprint(v)
	}
	return string(b)
}

// compactJSON strips insignificant whitespace so a raw payload stays on one line.
func compactJSON(raw json.RawMessage) string {
	var buf bytes.Buffer
	if err := json.Compact(&buf, raw); err != nil {
		return string(raw)
	}
	return buf.String()
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	// Cut on a rune boundary so the fragment is still valid UTF-8.
	cut := s[:n]
	for len(cut) > 0 && !utf8.ValidString(cut) {
		cut = cut[:len(cut)-1]
	}
	return cut + " …(truncated)"
}

// sectionHead matches a line that opens one of the four answer sections, e.g.
// "Status: …", "**Hypothesis:** …", "3. Kill-test — …", "## Fix". Deliberately
// loose: a local model asked for this shape produces a different flavour of
// markdown every run.
var sectionHead = regexp.MustCompile(`(?i)^[\s#>*_\-\d.)]*\b(status|hypothesis|kill[\s\-_]*test|fix)\b\s*[*_]{0,2}\s*[:\-—]\s*[*_]{0,2}\s*(.*)$`)

// sectionHeading matches a bare markdown heading with no separator ("## Fix",
// "**Status**").
var sectionHeading = regexp.MustCompile(`(?i)^\s*(?:#{1,6}|\*{2}|_{2})\s*(status|hypothesis|kill[\s\-_]*test|fix)\b\s*[*_]{0,2}\s*:?\s*$`)

// fenceLine matches a markdown code fence, which we drop: the Fix is rendered in
// a <pre> already, and a stray ``` would be flagged as "not a git command".
var fenceLine = regexp.MustCompile("^\\s*```")

// wrapperTagLine matches a line that is nothing but an XML-ish wrapper tag.
// Observed live (kagent 0.9.12 + qwen3:4b, 2026-08-17): the model wraps its whole
// answer in <response>…</response>, and the closing tag landed inside the Fix
// block where it rendered as "⚠ not a git command — review before running:
// </response>". Dropping tag-only lines is enough; anything with real content
// beside the tag is left alone.
var wrapperTagLine = regexp.MustCompile(`^\s*</?[A-Za-z][\w.:-]*\s*/?>\s*$`)

// verdictFromAnswer turns kagent's final answer into the side panel's four
// fields. The opening prompt asks for exactly this shape, so most runs parse; a
// run that ignores it (a small local model often does — module 10's whole first
// beat) still gets its answer shown, verbatim, under Hypothesis. Returning a
// filled-in verdict for an unstructured answer is the deliberate choice that a
// plain answer serves the room better than an error card.
func verdictFromAnswer(answer string) *Verdict {
	var kept []string
	for _, line := range strings.Split(answer, "\n") {
		if !fenceLine.MatchString(line) && !wrapperTagLine.MatchString(line) {
			kept = append(kept, line)
		}
	}
	text := strings.TrimSpace(strings.Join(kept, "\n"))
	if text == "" {
		return nil
	}

	sec := map[string][]string{}
	var preamble []string
	cur := ""
	for _, line := range strings.Split(text, "\n") {
		if key, rest, ok := matchSection(line); ok {
			cur = key
			if strings.TrimSpace(rest) != "" {
				sec[key] = append(sec[key], rest)
			}
			continue
		}
		if cur == "" {
			preamble = append(preamble, line)
			continue
		}
		sec[cur] = append(sec[cur], line)
	}
	join := func(k string) string { return strings.TrimSpace(strings.Join(sec[k], "\n")) }
	v := &Verdict{
		Status:     firstLine(join("status")),
		Hypothesis: join("hypothesis"),
		KillTest:   join("killtest"),
		Fix:        join("fix"),
	}
	if v.Status == "" && v.Hypothesis == "" && v.KillTest == "" && v.Fix == "" {
		// No recognisable shape at all — show the answer rather than nothing.
		return &Verdict{Hypothesis: text}
	}
	// A preamble before the first heading is only kept when it would otherwise be
	// the missing hypothesis; the same text has already streamed into the log as
	// narration, so nothing is lost by not repeating it in the panel.
	if v.Hypothesis == "" && len(preamble) > 0 {
		v.Hypothesis = strings.TrimSpace(strings.Join(preamble, "\n"))
	}
	return v
}

// matchSection reports whether a line opens a section, returning the canonical
// field key and whatever content followed on the same line.
func matchSection(line string) (key, rest string, ok bool) {
	if m := sectionHead.FindStringSubmatch(line); m != nil {
		return canonSection(m[1]), m[2], true
	}
	if m := sectionHeading.FindStringSubmatch(line); m != nil {
		return canonSection(m[1]), "", true
	}
	return "", "", false
}

// canonSection folds the spelling variants ("Kill-test", "kill test", "KILL_TEST")
// onto one key.
func canonSection(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if r >= 'a' && r <= 'z' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// firstLine keeps a one-line field one line — Status renders as a badge.
func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return s
}
