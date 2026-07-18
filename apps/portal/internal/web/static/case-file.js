// Case file — the single-shot agent investigation (module 10). A tiny, vendored
// SSE reader: the contract is POST /agent/ask with a JSON body, which the htmx
// SSE extension can't do (EventSource is GET-only), so we POST with fetch() and
// parse the text/event-stream response ourselves. No CDN, no dependency — this
// ships inside the binary like everything else.
//
// The server sends server-rendered HTML fragments per event. tool_call /
// tool_result / message lines append to the terminal-style log; verdict and
// error fragments replace the Status → Hypothesis → Kill-test → Fix panel.
(function () {
  function init() {
    var mount = document.getElementById("case-file");
    if (!mount) return;
    var open = document.getElementById("cf-open");
    if (!open) return;

    open.addEventListener("click", function () {
      var body = document.getElementById("cf-body");
      if (body) body.hidden = false;
      var log = document.getElementById("cf-log");
      var panel = document.getElementById("cf-panel");

      // A clean (re)start: reset the button, the log, and the panel so a Retry
      // doesn't stack onto a previous run.
      open.disabled = true;
      open.textContent = "Investigating…";
      if (log) log.innerHTML = "";
      if (panel) {
        panel.innerHTML =
          '<div class="case-card"><h4>Status</h4><p class="case-empty">investigating…</p></div>';
      }

      // On any failure, let the attendee try again without a page refresh — the
      // button says what it now does.
      function offerRetry() {
        open.disabled = false;
        open.textContent = "Retry investigation";
      }
      function fail(msg) {
        if (panel) {
          panel.innerHTML =
            '<div class="case-card cf-fail"><h4>Investigation failed</h4><p>' +
            msg +
            "</p></div>";
        }
        offerRetry();
      }

      fetch("/agent/ask", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          namespace: mount.dataset.namespace,
          kind: mount.dataset.kind,
          name: mount.dataset.name,
        }),
      })
        .then(function (resp) {
          if (!resp.ok || !resp.body) throw new Error("agent request failed");
          var reader = resp.body.getReader();
          var dec = new TextDecoder();
          var buf = "";
          function pump() {
            return reader.read().then(function (r) {
              if (r.done) {
                // Flush a final frame that arrived without its trailing blank
                // line (e.g. a proxy dropped it) so its event isn't lost.
                if (buf.trim() !== "") handleFrame(buf);
                done();
                return;
              }
              // Normalize CRLF → LF (a proxy may rewrite line endings) before
              // splitting on the blank-line frame boundary.
              buf = (buf + dec.decode(r.value, { stream: true })).replace(
                /\r\n?/g,
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
          return pump();
        })
        .catch(function () {
          fail("Could not reach the agent.");
        });

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
          if (log) {
            log.insertAdjacentHTML("beforeend", html);
            log.scrollTop = log.scrollHeight;
          }
        } else if (event === "verdict") {
          if (panel) panel.innerHTML = html;
        } else if (event === "error") {
          if (panel) panel.innerHTML = html;
          finished = true;
          offerRetry();
        } else if (event === "done") {
          done();
        }
      }

      var finished = false;
      function done() {
        if (finished) return;
        finished = true;
        if (open.textContent === "Investigating…")
          open.textContent = "Investigation complete";
      }
    });
  }

  if (document.readyState !== "loading") init();
  else document.addEventListener("DOMContentLoaded", init);
})();
