package web

// The Case file — the single-shot agent investigation on the application-detail
// page (module 10). The browser opens an investigation; the portal composes an
// opening prompt from the resource + its diagnostics rollup, streams it to the
// in-cluster Kagent k8s-agent over A2A (internal/kagent), and relays the agent's
// events back to the browser as Server-Sent Events. The agent is read-only
// (issue #126): the console renders its fix as copy-paste git commands, never as
// a mutating action.
//
// Transport note: the contract is POST /agent/ask with a JSON body, so the
// browser can't use htmx's SSE extension (EventSource is GET-only) — a tiny
// self-contained reader (static/case-file.js) POSTs and consumes the stream.
// The server side is what the hermetic tests pin: the SSE event sequence and
// the rendered fragments.
//
// Follow-up questions are a later ticket (#140): the session identity is already
// threaded through (one Kagent session per resource per browser session), so the
// seam is here — this handler just doesn't read `question` from a running
// conversation yet.

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"net/http"
	"regexp"
	"strings"

	"cloudbox.io/portal/internal/kagent"
	"cloudbox.io/portal/internal/kube"
)

// allowedKinds is the whitelist of resource kinds the Case file may investigate.
// The affordance only ever renders on the Application detail page (its mount
// sends kind="Application"), so that is the only kind we accept — a request for
// anything else is rejected before it can shape an LLM prompt.
var allowedKinds = map[string]bool{"Application": true}

// agentAvailable reports whether the Case file affordance can offer a live
// investigation: the kagent capability is present AND Healthy, and the client is
// wired. While it is still converging (present but not Healthy) the affordance
// stays locked, matching the console's other capability gating.
func agentAvailable(s *Server) bool {
	if s.Kagent == nil {
		return false
	}
	exists, healthy := s.currentSnapshot().AppHealthy("kagent")
	return exists && healthy
}

// HandleAgentAsk streams a single-shot investigation of one resource as SSE.
func HandleAgentAsk(s *Server, w http.ResponseWriter, r *http.Request) {
	var body struct {
		Namespace string `json:"namespace"`
		Kind      string `json:"kind"`
		Name      string `json:"name"`
		Question  string `json:"question"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	// Validate every input that feeds the LLM prompt. Namespace and name must be
	// DNS-1123 labels (kube.ValidName also bounds their length); kind must be one
	// the Case file actually investigates. Reject before composing any prompt.
	if body.Kind == "" {
		body.Kind = "Application"
	}
	if !kube.ValidName(body.Namespace) || !kube.ValidName(body.Name) || !allowedKinds[body.Kind] {
		http.Error(w, "invalid resource", http.StatusBadRequest)
		return
	}

	// Resolve (and mint, if absent) the browser identity BEFORE the SSE headers
	// — Set-Cookie must precede the first body write.
	uid := ensureUserID(w, r)

	// SSE headers. X-Accel-Buffering stops any reverse proxy from buffering the
	// stream (the events must reach the browser as they happen).
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("Connection", "keep-alive")
	h.Set("X-Accel-Buffering", "no")
	flusher, _ := w.(http.Flusher)
	// Commit the 200 + headers and flush now, before the (possibly slow) upstream
	// call, so the browser's stream reader leaves "connecting" immediately rather
	// than blocking on the first agent event.
	w.WriteHeader(http.StatusOK)
	if flusher != nil {
		flusher.Flush()
	}
	emit := func(event, fragment string) error {
		if err := writeSSE(w, event, fragment); err != nil {
			return err
		}
		if flusher != nil {
			flusher.Flush()
		}
		return nil
	}

	// Capability gate: the affordance renders locked unless kagent is present AND
	// Healthy, so this is the matching backend guard — refuse to call an agent
	// that isn't there (and distinguish "still converging" so the attendee knows
	// to wait rather than to enable it). The locked view never renders a mount
	// that could reach here; this defends the endpoint directly.
	exists, healthy := false, false
	if s.Kagent != nil {
		exists, healthy = s.currentSnapshot().AppHealthy("kagent")
	}
	switch {
	case !exists:
		emit("error", s.fragment("cf-error", "The investigation agent isn't enabled. Enable kagent from the catalog."))
		return
	case !healthy:
		emit("error", s.fragment("cf-error", "The investigation agent is still starting up — give it a moment and try again."))
		return
	}

	// Compose the opening prompt from the resource + its diagnostics rollup, so
	// the agent starts with the same evidence the panel shows. Best-effort: a
	// diagnostics read that fails just yields a leaner prompt (never an error).
	var diag kube.Diagnostics
	var why string
	if s.Kube != nil {
		diag, _ = s.Kube.NamespaceDiagnostics(r.Context(), body.Namespace)
		if body.Kind == "Application" {
			if app, err := s.Kube.GetApplication(r.Context(), body.Namespace, body.Name); err == nil && app != nil {
				why = app.Why()
			}
		}
	}
	prompt := buildInvestigationPrompt(body.Kind, body.Namespace, body.Name, why, diag, body.Question)

	req := kagent.Request{
		Namespace: body.Namespace,
		Kind:      body.Kind,
		Name:      body.Name,
		Prompt:    prompt,
		UserID:    uid,
		SessionID: sessionID(uid, body.Namespace, body.Kind, body.Name),
	}
	emitted := 0
	err := s.Kagent.Stream(r.Context(), req, func(e kagent.Event) error {
		var emitErr error
		switch e.Kind {
		case kagent.KindToolCall:
			emitErr = emit("tool_call", s.fragment("cf-toolcall", e))
		case kagent.KindToolResult:
			emitErr = emit("tool_result", s.fragment("cf-toolresult", e))
		case kagent.KindMessage:
			emitErr = emit("message", s.fragment("cf-message", e))
		case kagent.KindVerdict:
			emitErr = emit("verdict", s.fragment("cf-verdict", verdictFor(e.Verdict)))
		}
		if emitErr != nil {
			return emitErr
		}
		emitted++
		return nil
	})
	if err != nil {
		emit("error", s.fragment("cf-error", "The investigation didn't complete: "+err.Error()))
		return
	}
	// A clean stream that produced nothing means every frame fell through the
	// translation — almost always an A2A envelope mismatch. Make it visible
	// rather than ending on a silent "complete" with an empty log (reconcile
	// against live kagent at rehearsal — see spec #133 rehearsal gates).
	if emitted == 0 {
		emit("error", s.fragment("cf-error", "The agent responded in a format this console doesn't recognize. Check that your kagent version matches the workshop pin."))
		return
	}
	emit("done", "")
}

// verdictView is the sanitised verdict the cf-verdict fragment renders — same
// shape as kagent.Verdict, but with the Fix defensively reduced to git commands.
type verdictView struct {
	Status     string
	Hypothesis string
	KillTest   string
	Fix        string
}

// verdictFor builds the render model, running the Fix through sanitizeFix. A nil
// verdict (shouldn't happen — translate only tags a verdict when one is present)
// degrades to an empty card rather than panicking.
func verdictFor(v *kagent.Verdict) verdictView {
	if v == nil {
		return verdictView{}
	}
	return verdictView{
		Status:     v.Status,
		Hypothesis: v.Hypothesis,
		KillTest:   v.KillTest,
		Fix:        sanitizeFix(v.Fix),
	}
}

// sanitizeFix enforces the contract that the Fix is copy-paste git commands only
// — a prompt asks for that, it doesn't guarantee it. Each line is kept verbatim
// if it is blank, a comment, or a `git` command; any other line is rendered
// COMMENTED OUT with a visible warning, so pasting the whole block can't run a
// stray `kubectl apply`/`rm`/etc. Nothing is ever dropped silently.
func sanitizeFix(fix string) string {
	if strings.TrimSpace(fix) == "" {
		return fix
	}
	lines := strings.Split(fix, "\n")
	out := make([]string, len(lines))
	for i, line := range lines {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") || t == "git" || strings.HasPrefix(t, "git ") {
			out[i] = line
			continue
		}
		out[i] = "# ⚠ not a git command — review before running: " + line
	}
	return strings.Join(out, "\n")
}

// buildInvestigationPrompt turns the resource identity + its diagnostics rollup
// into the agent's opening prompt — the same evidence the Diagnostics panel
// shows, plus the read-only guardrail and the required answer shape
// (Status → Hypothesis → Kill-test → Fix as copy-paste git commands).
func buildInvestigationPrompt(kind, ns, name, why string, diag kube.Diagnostics, question string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "You are a read-only Kubernetes troubleshooting agent. Investigate why the %s %q in namespace %q is unhealthy.\n\n", kind, name, ns)
	if why != "" {
		fmt.Fprintf(&b, "The platform's status condition says: %s\n\n", why)
	}
	b.WriteString("What the console's diagnostics panel already shows:\n")
	if len(diag.PodTroubles) == 0 && len(diag.Warnings) == 0 {
		b.WriteString("- (no obvious container faults or warning events yet)\n")
	}
	for _, t := range diag.PodTroubles {
		fmt.Fprintf(&b, "- pod %s container %s: %s — %s\n", t.Pod, t.Container, t.Reason, t.Message)
	}
	for _, ev := range diag.Warnings {
		fmt.Fprintf(&b, "- event %s %s/%s: %s\n", ev.Reason, ev.InvolvedObject.Kind, ev.InvolvedObject.Name, ev.Message)
	}
	b.WriteString("\n")
	if question != "" {
		fmt.Fprintf(&b, "The operator also asks: %s\n\n", question)
	}
	b.WriteString("Use only read-only tools. Conclude with a one-line Status, a Hypothesis, " +
		"a Kill-test (the single observation that would falsify the hypothesis), and a Fix " +
		"expressed only as copy-paste git commands the operator runs themselves — never apply " +
		"changes to the cluster yourself.\n")
	return b.String()
}

// fragment renders a named template to a string for embedding in an SSE frame.
// A render error degrades to its escaped text rather than breaking the stream.
func (s *Server) fragment(name string, data any) string {
	var buf bytes.Buffer
	if err := s.Tmpl.ExecuteTemplate(&buf, name, data); err != nil {
		return template.HTMLEscapeString(err.Error())
	}
	return strings.TrimSpace(buf.String())
}

// writeSSE writes one SSE frame: a named event and an HTML-fragment payload.
// The fragment is split across `data:` lines (SSE forbids raw newlines in a
// data field); the browser rejoins them with "\n", preserving multi-line HTML.
// It returns the first write error (e.g. the browser disconnected), so the
// caller's emit callback can report it up through Stream's emit-error
// early-exit path instead of writing into a dead connection.
func writeSSE(w io.Writer, event, data string) error {
	if _, err := fmt.Fprintf(w, "event: %s\n", event); err != nil {
		return err
	}
	if data != "" {
		for _, line := range strings.Split(data, "\n") {
			if _, err := fmt.Fprintf(w, "data: %s\n", line); err != nil {
				return err
			}
		}
	}
	_, err := fmt.Fprint(w, "\n")
	return err
}

// uidShape is exactly what mintID produces: 32 lowercase hex chars. An incoming
// cookie that doesn't match (garbage, oversized, injected) is not trusted — it is
// replaced with a freshly minted identity.
var uidShape = regexp.MustCompile(`^[0-9a-f]{32}$`)

// ensureUserID resolves the A2A identity (X-User-ID) for this browser session,
// minting and setting the `cbx_uid` cookie when it is absent or malformed so the
// identity is stable across requests and always well-shaped. Kagent is authless
// in-cluster, so this is a per-browser handle, not a credential. Same cookie
// idiom as the project selector (HttpOnly, Lax; Secure when the request is TLS).
// The cookie must be set before the SSE body is written.
func ensureUserID(w http.ResponseWriter, r *http.Request) string {
	if c, err := r.Cookie("cbx_uid"); err == nil && uidShape.MatchString(c.Value) {
		return c.Value
	}
	id := mintID()
	http.SetCookie(w, &http.Cookie{
		Name:     "cbx_uid",
		Value:    id,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   r.TLS != nil,
	})
	return id
}

// mintID returns a fresh random per-browser identity; on the vanishingly
// unlikely rand failure it degrades to a fixed handle rather than erroring.
func mintID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "cloudbox-user"
	}
	return hex.EncodeToString(b[:])
}

// sessionID scopes one Kagent conversation to one resource per browser session —
// the (uid, resource) pair, so two browsers get distinct sessions. This is the
// seam a later ticket (#140) reuses to continue the same conversation for
// follow-up questions.
func sessionID(uid, ns, kind, name string) string {
	return uid + ":" + ns + ":" + kind + ":" + name
}
