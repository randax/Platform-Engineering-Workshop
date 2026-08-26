---
layout: section
transition: view-transition
---

# How today works

<!--
Five minutes on mechanics, then hands on keyboards. This section is the contract for the whole day — worth getting right, then never repeating.
-->

---

# The map: one core path, then five doors

| # | Module | Time |
|---|--------|------|
| 00 | Setup & pre-flight | running now, in the background |
| 01 | Talos + Cilium — your own cloud | 30 min |
| 02 | GitOps — Gitea + ArgoCD | 30 min |
| 03 | Data — Postgres + S3 | 30 min |
| 04 | Self-service — Crossplane v2 | 25 min |
| 05 | Debug it (with or without AI) | 20 min |
| — | **Five doors** — start with door 0: the marked trail (06–10) | the last 45 |

<!--
THIS TABLE IS THE DAY'S ONLY TIMELINE — every other slide's timebox is derived from it, so if a number moves, move it here first.

Core is 01–05: 135 minutes of guided content, one 10-minute break (after 03), and module 00 running underneath the intro rather than in a slot of its own. There is no second break: the room goes self-paced at the pivot, so coffee is whenever you want it from there. That leaves the last 45 for the finale, which is not a sixth module but a choice of five doors. Door 0 is the one to recommend out loud: the marked trail through modules 06–10 in order — serverless, in-cluster CI, the Console, the picture-pipeline capstone, day-2 AI ops — rehearsed, hinted and verified, and written to finish at home.

Expectations management, said out loud: "We planned half of what fits. If you only finish the core, you've built a real platform. The doors are for the final block — and for your couch afterwards; nothing depends on them and everything is public."

Every timebox here is a soft target — we walk the solution when the timer ends regardless, and catch-up.sh absorbs the rest. The door block is deliberately the day's buffer: it grows if we run fast and shrinks if we don't. The close never moves — hard stop 10 minutes before the end, and we finish together.
-->

---

# The lab contract

<div class="grid grid-cols-2 gap-3 mt-4">
  <div class="principle"><div class="ico"><span class="svgi i-target"></span></div><div class="name">Outcome, not steps</div><div class="tie">the README says <em>reach state X</em></div></div>
  <div class="principle"><div class="ico"><span class="svgi i-layers"></span></div><div class="name">Layered hints</div><div class="tie">free, collapsible — last one is the answer</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-check" style="color:var(--jz-run)"></span></div><div class="name"><code>./verify.sh</code></div><div class="tie">checks your live cluster → green = done</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-fast-forward"></span></div><div class="name"><code>catch-up.sh &lt;n&gt;</code></div><div class="tie">jump to any module's end-state</div></div>
</div>

<!--
This is how every single module works, so learn it once:

1. Each lab README says "make your cluster reach state X" and roughly where to look. It deliberately does NOT hand you 12 commands to paste — pasting teaches nothing.
2. Hints escalate from a guiding question to the exact command, in collapsed blocks. Open as many as you need; nobody is counting and there's no penalty. The last hint is always the full solution — using it is fine, understanding it is required.
3. verify.sh is the finish line: it runs many small checks against your RUNNING cluster (never against your files), prints a green check per pass and an actionable FAIL per miss, exits 0 when the outcome is true.
4. catch-up.sh N force-pushes the canonical end-state for module N to your in-cluster Gitea and lets ArgoCD converge — scripted state, not hope. Broke something interesting? That's fine, catch-up exists precisely so you can experiment fearlessly. Say the destigmatizing line out loud and mean it: "catch-up is not failure — it's how the workshop is designed to absorb variance."

Also mention explain-backs: at each module boundary, two minutes, tell your neighbor WHY it works. A fix you can't explain isn't done yet.

THE LAB-LAUNCH RITUAL (same every module — presenter discipline, researched not vibes):
- The GO slide STAYS PROJECTED for the entire lab. It carries the outcome, the literal first command, the verify command, and the timebox — a room of 40 self-paced people re-orients from it constantly. Never advance past it to "peek at the next section" while people work.
- Before releasing the room, say the first two minutes aloud — the literal first command to type. Lab-start confusion is almost always "what's my first action?", not "what's the goal?".
- Run a countdown timer next to the deck (external — stagetimer.io or similar) that changes color near the end, and ALSO call "two minutes" verbally: a silent timer fails silently.
- State every timebox as a soft target: "we walk the solution at :35 regardless" — slower attendees relax because catch-up exists, and the walk-through is announced, not sprung.
- One call-back signal, announced now, used identically all day (we use: timer hits zero + both speakers stand front-center). Never try to talk over 40 keyboards.
-->

---

# Getting help

- <span class="svgi i-sticky-note" style="color:var(--jz-run)"></span> green sticky — "I'm fine"
- <span class="svgi i-sticky-note" style="color:#e5484d"></span> red sticky — "come by, please"
- Helpers roam; no hand-raising needed
- Recurring questions land on the front wall — answered for everyone at each re-sync
- Pairing is encouraged — arguably better
- Laptop says no? Devcontainer lifeboat

<!--
Point out the helpers by name and location. The sticky-note protocol means nobody sits blocked with a hand in the air: red sticky up, keep poking at something else, a helper finds you.

Pairing: the whole workshop works as a pair on one machine — you'll talk through more and type less. If your pre-flight fails, pair up or use the devcontainer: the repo ships a .devcontainer that runs identical content in GitHub Codespaces (4 cores / 16 GB machine). Acknowledge the irony out loud — the lifeboat for the sovereignty workshop is Microsoft's cloud, which is exactly why it's the lifeboat and not the boat.

When the room drifts apart, we'll walk the solution on screen to re-sync. That's normal, not falling behind.

The question backlog, explained to the room: when a helper answers the same question twice, it goes on a sticky on the front wall; at each walk-the-solution the lead triages them aloud — "three of you hit X, here's the answer for everyone". It turns 1:1 helper answers into whole-room teaching. Helpers: docs/HELPERS.md has your side of this (zones, patrol pattern, sticky-count checkpoints).
-->

---

# AI assistants are welcome. Really.

- Claude Code, Copilot, kubectl-ai — bring it
- Labs are outcomes, so pasting can't win
- **Tutor, not chauffeur** — the repo tells your agent to coach, not solve
- Env/tooling broken? Sic the agent on it — yak-shaving is not the lesson
- Finish line: green verify + explain-back
- Verify what agents claim — module 05 drills this

<!--
Say this clearly because attendees will otherwise hide their terminals: using an AI assistant is explicitly fine in every module. We designed for it — the labs state outcomes rather than command lists precisely because copying 12 commands, yourself or via an LLM, teaches nothing.

The goal was never "typed the commands yourself". It's a running platform PLUS your ability to explain it. Two house rules:
1. verify.sh and the explain-back are the finish line, not the last command an agent ran.
2. When an assistant tells you something about YOUR cluster, check it against the cluster before acting. Module 05 exists to make that instinct permanent — including one fault where the obvious AI answer is plausible and wrong. That's a promise, not a threat.

The tutor line, said with a smile and total honesty: the repo's CLAUDE.md/AGENTS.md asks agents to coach rather than solve — Socratic questions, next hint layer, no pasted solutions. It's advisory and they can bypass it; the point isn't enforcement, it's that a workshop your agent completes teaches your agent. One carve-out to state explicitly, because it's the opposite rule: broken environments (Docker, mise, half-pulled images) are fair game for full AI firepower — nobody came here to learn yak-shaving. Helpers apply the same split: coach on lab content, fix machines outright.
-->

---

# Your progress, live

- Cloudbox Console → **Workshop** page
- One row per module, inferred from cluster
- It reads live state — no self-reporting
- `http://portal.cloudbox.k8s.test/workshop` (after module 02)

<!--
Once the platform's portal is running (it arrives via the catalog; you'll meet it properly in module 08), its Workshop page shows a checklist of all ten modules — each row inferred from your live cluster state: nodes ready, kube-proxy absent, Gitea healthy, a CNPG cluster in demo, WorkshopDatabases present, thumbnails in the images bucket, and so on.

Two honest caveats to mention: it's a hint, not a judge — verify.sh in each lab folder is the authoritative check; and module 05 (fault-fixing) can't be inferred from end-state at all.

We'll keep it on the projector between modules as the room's shared progress board. It's also a nice teaser: the page itself is ~100 lines of Go reading the Kubernetes API — you'll read its source in module 08.

Your pre-flight has been running since minute 10 — triage check now, then module 01.
-->
