---
layout: section
transition: view-transition
---

# How today works

<!--
Five minutes on mechanics, then hands on keyboards. This section is the contract for the whole day. Worth getting right, then never repeating.
-->

---

# The map: one core path, then five doors

| # | Module | Time |
|---|--------|------|
| 00 | Setup & pre-flight | running now, in the background |
| 01 | Talos + Cilium: your own cloud | 20 min |
| 02 | GitOps: Gitea + ArgoCD | 20 min |
| 03 | Data: Postgres + S3 | 20 min |
| 04 | Self-service: Crossplane v2 | 20 min |
| 05 | Debug it (with or without AI) | 15 min |
| 06 | Serverless: Knative | 15 min |
| 09 | **Capstone**: the picture pipeline | 25 min |
| — | **Five doors**, start with door 0 (07 · 08 · 10) | the last 45 |

<!--
THIS TABLE IS THE DAY'S ONLY TIMELINE. Every other slide's timebox is derived from it, so if a number moves, move it here first.

The guided day is 135 minutes: modules 01–05 at the tempo above (95), then serverless (06) and the capstone (09), because a platform without scale-to-zero and without something running on top of it isn't finished, and those two are what make the day add up. Module 00 runs underneath the intro rather than in a slot of its own, and there is one 10-minute break, after module 03; from the pivot on the room is self-paced, so coffee is whenever you want it.

That leaves the last 45 for a choice of five doors. Door 0 is the one to recommend out loud, the marked trail: in-cluster CI (07), the Console's source (08) and day-2 AI ops (10), rehearsed, hinted, verified, and written to finish at home.

Expectations management, said out loud: "We planned half of what fits. If you only finish the core, you've built a real platform. The doors are for the final block, and for your couch afterwards; nothing depends on them and everything is public."

Every timebox here is a soft target. We walk the solution when the timer ends regardless, and catch-up.sh absorbs the rest. The door block is deliberately the day's buffer: it grows if we run fast and shrinks if we don't. The close never moves. Hard stop 10 minutes before the end, and we finish together.
-->

---

# The lab contract

<div class="grid grid-cols-2 gap-3 mt-4">
  <div class="principle"><div class="ico"><span class="svgi i-target"></span></div><div class="name">Outcome, not steps</div><div class="tie">the README says <em>reach state X</em></div></div>
  <div class="principle"><div class="ico"><span class="svgi i-layers"></span></div><div class="name">Layered hints</div><div class="tie">free, collapsible; last one is the answer</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-check" style="color:var(--jz-run)"></span></div><div class="name"><code>./verify.sh</code></div><div class="tie">checks your live cluster · green = done</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-fast-forward"></span></div><div class="name"><code>catch-up.sh &lt;n&gt;</code></div><div class="tie">jump to any module's end-state</div></div>
</div>

<!--
This is how every single module works, so learn it once:

1. Each lab README says "make your cluster reach state X" and roughly where to look. It deliberately does NOT hand you 12 commands to paste. Pasting teaches nothing.
2. Hints escalate from a guiding question to the exact command, in collapsed blocks. Open as many as you need; nobody is counting and there's no penalty. The last hint is always the full solution. Using it is fine, understanding it is required.
3. verify.sh is the finish line: it runs many small checks against your RUNNING cluster (never against your files), prints a green check per pass and an actionable FAIL per miss, exits 0 when the outcome is true.
4. catch-up.sh N force-pushes the canonical end-state for module N to your in-cluster Gitea and lets ArgoCD converge. Scripted state, not hope. Broke something interesting? That's fine, catch-up exists precisely so you can experiment fearlessly. Say the destigmatizing line out loud and mean it: "catch-up is not failure, it's how the workshop is designed to absorb variance."

Also mention explain-backs: at each module boundary, two minutes, tell your neighbor WHY it works. A fix you can't explain isn't done yet.

THE LAB-LAUNCH RITUAL (same every module; presenter discipline, researched not vibes):
- The GO slide STAYS PROJECTED for the entire lab. It carries the outcome, the literal first command, the verify command, and the timebox. A room of 40 self-paced people re-orients from it constantly. Never advance past it to "peek at the next section" while people work.
- Before releasing the room, say the first two minutes aloud, down to the literal first command to type. Lab-start confusion is almost always "what's my first action?", not "what's the goal?".
- Run a countdown timer next to the deck (external, stagetimer.io or similar) that changes color near the end, and ALSO call "two minutes" verbally: a silent timer fails silently.
- State every timebox as a soft target: "we walk the solution at :35 regardless". Slower attendees relax because catch-up exists, and the walk-through is announced, not sprung.
- One call-back signal, announced now, used identically all day (we use: timer hits zero + both speakers stand front-center). Never try to talk over 40 keyboards.
-->

---

# Getting help

- <span class="svgi i-sticky-note" style="color:var(--jz-run)"></span> green sticky: "I'm fine"
- <span class="svgi i-sticky-note" style="color:#e5484d"></span> red sticky: "come by, please"
- Two of us, no helper crew; one walks the floor during labs
- Red up? Keep working: next hint layer, or a neighbor
- Recurring questions land on the front wall, answered for everyone at each re-sync
- Pairing is encouraged, arguably better
- Laptop says no? Devcontainer lifeboat

<!--
Say the staffing plainly: it's the two of us, no helper crew. The sticky protocol survives because it batches well. A raised hand blocks you, a sticky doesn't. Be honest about latency: during each lab one of us anchors the projector and the other walks the floor, so a red sticky gets picked up on the next pass, not in thirty seconds. While waiting: next hint layer, verify.sh output, or the neighbor who's already green.

Pairing: the whole workshop works as a pair on one machine. You'll talk through more and type less. If your pre-flight fails, pair up or use the devcontainer: the repo ships a .devcontainer that runs identical content in GitHub Codespaces (4 cores / 16 GB machine). Acknowledge the irony out loud: the lifeboat for the sovereignty workshop is Microsoft's cloud, which is exactly why it's the lifeboat and not the boat.

When the room drifts apart, we'll walk the solution on screen to re-sync. That's normal, not falling behind.

The question backlog, explained to the room: when either of us answers the same question twice, it goes on a sticky on the front wall; at each walk-the-solution the presenter triages them aloud: "three of you hit X, here's the answer for everyone". With two of us this is load-bearing, not nice-to-have. We cannot answer the same question fifteen times 1:1. Our side of the floor plan is docs/RUNBOOK.md.
-->

---

# AI assistants are welcome. Really.

- Claude Code, Copilot, kubectl-ai: bring it
- Labs are outcomes, so pasting can't win
- **Tutor, not chauffeur**: the repo tells your agent to coach, not solve
- Env/tooling broken? Sic the agent on it. Yak-shaving is not the lesson
- Finish line: green verify + explain-back
- Verify what agents claim; module 05 drills this

<!--
Say this clearly because attendees will otherwise hide their terminals: using an AI assistant is explicitly fine in every module. We designed for it. The labs state outcomes rather than command lists precisely because copying 12 commands, yourself or via an LLM, teaches nothing.

The goal was never "typed the commands yourself". It's a running platform PLUS your ability to explain it. Two house rules:
1. verify.sh and the explain-back are the finish line, not the last command an agent ran.
2. When an assistant tells you something about YOUR cluster, check it against the cluster before acting. Module 05 exists to make that instinct permanent, including one fault where the obvious AI answer is plausible and wrong. That's a promise, not a threat.

The tutor line, said with a smile and total honesty: the repo's CLAUDE.md/AGENTS.md asks agents to coach rather than solve. Socratic questions, next hint layer, no pasted solutions. It's advisory and they can bypass it; the point isn't enforcement, it's that a workshop your agent completes teaches your agent. One carve-out to state explicitly, because it's the opposite rule: broken environments (Docker or tbx, mise, half-pulled images) are fair game for full AI firepower. Nobody came here to learn yak-shaving. We apply the same split on the floor: coach on lab content, fix machines outright.
-->

---

# Your progress, live

- Cloudbox Console → **Workshop** page
- One row per module, inferred from cluster
- It reads live state, no self-reporting
- On the projector all day · yours once the Console lands
- `http://portal.cloudbox.k8s.test/workshop`

<!--
The portal arrives via the catalog: on the projector cluster from the start, and on yours with the capstone's setup in module 09 (module 08, on door 0, is about reading its source rather than turning it on). Its Workshop page shows a checklist of all eleven modules, each row inferred from your live cluster state: nodes ready, kube-proxy absent, Gitea healthy, a CNPG cluster in demo, WorkshopDatabases present, thumbnails in the images bucket, and so on.

Two honest caveats to mention: it's a hint, not a judge (verify.sh in each lab folder is the authoritative check), and module 05 (fault-fixing) can't be inferred from end-state at all.

We'll keep it on the projector between modules as the room's shared progress board. It's also a nice teaser: the page itself is ~100 lines of Go reading the Kubernetes API. You'll read its source in module 08.

Your pre-flight has been running since minute 10. Triage check now, then module 01.
-->
