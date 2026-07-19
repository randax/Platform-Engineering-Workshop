// Case file — the agent investigation (module 10). A tiny, vendored SSE reader:
// the contract is POST /agent/ask with a JSON body, which the htmx SSE extension
// can't do (EventSource is GET-only), so we POST with fetch() and parse the
// text/event-stream response ourselves. No CDN, no dependency — this ships inside
// the binary like everything else.
//
// The server sends server-rendered HTML fragments per event. The OPENING
// investigation routes the verdict to the side panel; FOLLOW-UP questions (#140)
// continue the same Kagent session (same resource + browser session) and stream
// their answer into the log while the hypothesis panel stays pinned.
(function () {
  function init() {
    var mount = document.getElementById("case-file");
    if (!mount) return;
    var open = document.getElementById("cf-open");
    if (!open) return;
    var log = document.getElementById("cf-log");
    var panel = document.getElementById("cf-panel");
    var followForm = document.getElementById("cf-followup");
    var followInput = document.getElementById("cf-question");
    var followBtn = document.getElementById("cf-ask");

    function appendLog(html) {
      if (log) {
        log.insertAdjacentHTML("beforeend", html);
        log.scrollTop = log.scrollHeight;
      }
    }
    function escapeHtml(s) {
      return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    function setFollowEnabled(on) {
      if (followInput) followInput.disabled = !on;
      if (followBtn) followBtn.disabled = !on;
    }

    // stream POSTs /agent/ask and routes the SSE events. `route` decides where a
    // verdict lands: "panel" (the opening investigation) or "log" (a follow-up,
    // so the panel stays pinned). onVerdict fires when a verdict arrives; the
    // returned promise resolves { ok } when the stream ends.
    function stream(question, route, onVerdict) {
      var body = {
        namespace: mount.dataset.namespace,
        kind: mount.dataset.kind,
        name: mount.dataset.name,
      };
      if (question) body.question = question;
      return fetch("/agent/ask", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      })
        .then(function (resp) {
          if (!resp.ok || !resp.body) throw new Error("agent request failed");
          var reader = resp.body.getReader();
          var dec = new TextDecoder();
          var buf = "";
          var ended = false;
          return new Promise(function (resolve) {
            var errored = false; // a server `error` fragment was shown
            function finish(ok) {
              if (ended) return;
              ended = true;
              // Stop the background pump loop from consuming the rest of the
              // stream once we've settled (error event, early exit).
              reader.cancel().catch(function () {});
              resolve({ ok: ok, errored: errored });
            }
            function handleFrame(frame) {
              var event = "message";
              var data = [];
              frame.split("\n").forEach(function (line) {
                if (line.indexOf("event:") === 0) event = line.slice(6).trim();
                else if (line.indexOf("data:") === 0)
                  data.push(line.slice(5).replace(/^ /, ""));
              });
              var html = data.join("\n");
              if (event === "tool_call" || event === "tool_result" || event === "message") {
                appendLog(html);
              } else if (event === "verdict") {
                if (route === "panel" && panel) panel.innerHTML = html;
                else appendLog(html);
                if (onVerdict) onVerdict();
              } else if (event === "error") {
                errored = true;
                if (route === "panel" && panel) panel.innerHTML = html;
                else appendLog(html);
                finish(false);
              } else if (event === "done") {
                finish(true);
              }
            }
            function pump() {
              return reader.read().then(function (r) {
                if (r.done) {
                  // Flush a final frame that arrived without its trailing blank
                  // line (e.g. a proxy dropped it) so its event isn't lost.
                  if (buf.trim() !== "") handleFrame(buf);
                  finish(true);
                  return;
                }
                // Normalize CRLF → LF (a proxy may rewrite line endings) before
                // splitting on the blank-line frame boundary. Match only the full
                // \r\n: on the concatenated buffer a boundary-split pair is
                // reassembled before replacement, so a lone \r from a chunk edge
                // is never mistaken for a line ending (nothing we talk to emits
                // lone-CR framing).
                buf = (buf + dec.decode(r.value, { stream: true })).replace(
                  /\r\n/g,
                  "\n"
                );
                var i;
                while ((i = buf.indexOf("\n\n")) >= 0) {
                  handleFrame(buf.slice(0, i));
                  buf = buf.slice(i + 2);
                }
                return pump();
              });
            }
            // A mid-stream read failure (connection drop) must reach the failure
            // path, not leave the promise unsettled and the UI stuck.
            pump().catch(function () {
              finish(false);
            });
          });
        })
        .catch(function () {
          return { ok: false };
        });
    }

    // The opening investigation.
    open.addEventListener("click", function () {
      var cfBody = document.getElementById("cf-body");
      if (cfBody) cfBody.hidden = false;
      open.disabled = true;
      open.textContent = "Investigating…";
      if (log) log.innerHTML = "";
      if (panel) {
        panel.innerHTML =
          '<div class="case-card"><h4>Status</h4><p class="case-empty">investigating…</p></div>';
      }
      setFollowEnabled(false); // follow-ups only after a verdict arrives

      var gotVerdict = false;
      stream(null, "panel", function () {
        gotVerdict = true;
        if (followForm) followForm.hidden = false;
        setFollowEnabled(true);
        if (followInput) followInput.focus();
      }).then(function (res) {
        if (res.ok) {
          if (open.textContent === "Investigating…")
            open.textContent = "Investigation complete";
        } else {
          open.disabled = false;
          open.textContent = "Retry investigation";
          // Only write the generic failure when NEITHER a verdict nor a specific
          // server error fragment reached the panel — otherwise we'd clobber the
          // agent's own message with "Could not reach the agent."
          if (panel && !gotVerdict && !res.errored) {
            panel.innerHTML =
              '<div class="case-card cf-fail"><h4>Investigation failed</h4><p>Could not reach the agent.</p></div>';
          }
        }
      });
    });

    // Follow-up questions — continue the same session; answers stream into the log.
    if (followForm) {
      followForm.addEventListener("submit", function (e) {
        e.preventDefault();
        var q = (followInput.value || "").trim();
        if (!q) return;
        setFollowEnabled(false);
        appendLog('<div class="cf-line cf-you">› ' + escapeHtml(q) + "</div>");
        followInput.value = "";
        stream(q, "log", null).then(function (res) {
          setFollowEnabled(true);
          if (followInput) followInput.focus();
          if (!res.ok) {
            appendLog('<div class="cf-line cf-obs">(follow-up failed — try again)</div>');
          }
        });
      });
    }
  }

  if (document.readyState !== "loading") init();
  else document.addEventListener("DOMContentLoaded", init);
})();
