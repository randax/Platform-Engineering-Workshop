---
layout: section
---

# How today works

<!--
Five minutes on mechanics, then hands on keyboards. This section is the contract for the whole day — worth getting right, then never repeating.
-->

---

# The map: 10 modules, 2 tiers

| # | Module | Time |
|---|--------|------|
| 00 | Setup & pre-flight | 15 min |
| 01 | Talos + Cilium — your own cloud | 35 min |
| 02 | GitOps — Gitea + ArgoCD | 35 min |
| 03 | Data — Postgres + S3 | 35 min |
| 04 | Self-service — Crossplane v2 | 35 min |
| 05 | Debug it (with or without AI) | 25 min |
| 06–09 | Serverless · CI · Portal · Capstone | stretch |

<!--
Core is 00–05 — that's the plan, and it fits with slack. 06–09 are stretch: serverless (Knative), in-cluster CI (Argo Workflows + BuildKit + Zot), the Cloudbox Console portal, and the capstone picture pipeline that wires everything together.

Expectations management, said out loud: "We planned half of what fits. If you only finish the core, you've built a real platform. The stretch modules are for the fast 20% — and for your couch afterwards; nothing later depends on them and everything is public."

Two 10-minute breaks: after module 03 and after module 05. The last 30 minutes are protected for open tinkering and weird questions.
-->

---

# The lab contract

- README states an **outcome**, not steps
- **Hints** are layered, free, collapsible
- **`./verify.sh`** checks your live cluster
- Green verify = module done
- Behind? **`./scripts/catch-up.sh <module>`**

<!--
This is how every single module works, so learn it once:

1. Each lab README says "make your cluster reach state X" and roughly where to look. It deliberately does NOT hand you 12 commands to paste — pasting teaches nothing.
2. Hints escalate from a guiding question to the exact command, in collapsed blocks. Open as many as you need; nobody is counting and there's no penalty. The last hint is always the full solution — using it is fine, understanding it is required.
3. verify.sh is the finish line: it runs many small checks against your RUNNING cluster (never against your files), prints a green check per pass and an actionable FAIL per miss, exits 0 when the outcome is true.
4. catch-up.sh N force-pushes the canonical end-state for module N to your in-cluster Gitea and lets ArgoCD converge — scripted state, not hope. Broke something interesting? That's fine, catch-up exists precisely so you can experiment fearlessly.

Also mention explain-backs: at each module boundary, two minutes, tell your neighbor WHY it works. A fix you can't explain isn't done yet.
-->

---

# Getting help

- 🟩 green sticky — "I'm fine"
- 🟥 red sticky — "come by, please"
- Helpers roam; no hand-raising needed
- Pairing is encouraged — arguably better
- Laptop says no? Devcontainer lifeboat

<!--
Point out the helpers by name and location. The sticky-note protocol means nobody sits blocked with a hand in the air: red sticky up, keep poking at something else, a helper finds you.

Pairing: the whole workshop works as a pair on one machine — you'll talk through more and type less. If your pre-flight fails, pair up or use the devcontainer: the repo ships a .devcontainer that runs identical content in GitHub Codespaces (4 cores / 16 GB machine). Acknowledge the irony out loud — the lifeboat for the sovereignty workshop is Microsoft's cloud, which is exactly why it's the lifeboat and not the boat.

When the room drifts apart, we'll walk the solution on screen to re-sync. That's normal, not falling behind.
-->

---

# AI assistants are welcome. Really.

- Claude Code, Copilot, kubectl-ai — bring it
- Labs are outcomes, so pasting can't win
- Finish line: green verify + explain-back
- Verify what agents claim — module 05 drills this

<!--
Say this clearly because attendees will otherwise hide their terminals: using an AI assistant is explicitly fine in every module. We designed for it — the labs state outcomes rather than command lists precisely because copying 12 commands, yourself or via an LLM, teaches nothing.

The goal was never "typed the commands yourself". It's a running platform PLUS your ability to explain it. Two house rules:
1. verify.sh and the explain-back are the finish line, not the last command an agent ran.
2. When an assistant tells you something about YOUR cluster, check it against the cluster before acting. Module 05 exists to make that instinct permanent — including one fault where the obvious AI answer is plausible and wrong. That's a promise, not a threat.
-->

---

# Your progress, live

- Cloudbox Console → **Workshop** page
- One row per module, inferred from cluster
- It reads live state — no self-reporting
- `http://localhost:30600/workshop` (after module 02)

<!--
Once the platform's portal is running (it arrives via the catalog; you'll meet it properly in module 08), its Workshop page shows a checklist of all ten modules — each row inferred from your live cluster state: nodes ready, kube-proxy absent, Gitea healthy, a CNPG cluster in demo, WorkshopDatabases present, thumbnails in the images bucket, and so on.

Two honest caveats to mention: it's a hint, not a judge — verify.sh in each lab folder is the authoritative check; and module 05 (fault-fixing) can't be inferred from end-state at all.

We'll keep it on the projector between modules as the room's shared progress board. It's also a nice teaser: the page itself is ~100 lines of Go reading the Kubernetes API — you'll read its source in module 08.

Now — let's make sure everyone's laptop is ready. Module 00.
-->
