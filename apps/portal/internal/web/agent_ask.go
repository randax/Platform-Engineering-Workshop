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
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"net/http"
	"strings"

	"cloudbox.io/portal/internal/kagent"
	"cloudbox.io/portal/internal/kube"
)

// agentAvailable reports whether the Case file affordance can offer a live
// investigation: the kagent capability is present in the cluster and the client
// is wired. Otherwise the affordance renders in the locked-capability style.
func agentAvailable(s *Server) bool {
	if s.Kagent == nil {
		return false
	}
	exists, _ := s.currentSnapshot().AppHealthy("kagent")
	return exists
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
	if !kube.ValidName(body.Namespace) || !kube.ValidName(body.Name) {
		http.Error(w, "invalid resource", http.StatusBadRequest)
		return
	}
	if body.Kind == "" {
		body.Kind = "Application"
	}

	// SSE headers. X-Accel-Buffering stops any reverse proxy from buffering the
	// stream (the events must reach the browser as they happen).
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("Connection", "keep-alive")
	h.Set("X-Accel-Buffering", "no")
	flusher, _ := w.(http.Flusher)
	emit := func(event, fragment string) {
		writeSSE(w, event, fragment)
		if flusher != nil {
			flusher.Flush()
		}
	}

	// Capability gate: the affordance renders locked when kagent is absent, so
	// this is the matching backend guard — refuse to call an agent that isn't
	// there. (The locked view also never renders a mount that could reach here.)
	exists, _ := s.currentSnapshot().AppHealthy("kagent")
	if !exists || s.Kagent == nil {
		emit("error", s.fragment("cf-error", "The investigation agent isn't enabled. Enable kagent from the catalog."))
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
		UserID:    userID(r),
		SessionID: sessionID(r, body.Namespace, body.Kind, body.Name),
	}
	err := s.Kagent.Stream(r.Context(), req, func(e kagent.Event) error {
		switch e.Kind {
		case kagent.KindToolCall:
			emit("tool_call", s.fragment("cf-toolcall", e))
		case kagent.KindToolResult:
			emit("tool_result", s.fragment("cf-toolresult", e))
		case kagent.KindMessage:
			emit("message", s.fragment("cf-message", e))
		case kagent.KindVerdict:
			emit("verdict", s.fragment("cf-verdict", e.Verdict))
		}
		return nil
	})
	if err != nil {
		emit("error", s.fragment("cf-error", "The investigation didn't complete: "+err.Error()))
		return
	}
	emit("done", "")
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
func writeSSE(w io.Writer, event, data string) {
	fmt.Fprintf(w, "event: %s\n", event)
	if data != "" {
		for _, line := range strings.Split(data, "\n") {
			fmt.Fprintf(w, "data: %s\n", line)
		}
	}
	fmt.Fprint(w, "\n")
}

// userID is the A2A identity (X-User-ID). Kagent is authless in-cluster; this
// is a stable per-browser handle, not a credential. The lab is single-user and
// disposable, so an absent cookie falls back to a fixed identity.
func userID(r *http.Request) string {
	if c, err := r.Cookie("cbx_uid"); err == nil && c.Value != "" {
		return c.Value
	}
	return "cloudbox-user"
}

// sessionID scopes one Kagent conversation to one resource per browser session
// — the seam a later ticket (#140) reuses to continue the same conversation for
// follow-up questions.
func sessionID(r *http.Request, ns, kind, name string) string {
	return userID(r) + ":" + ns + ":" + kind + ":" + name
}
