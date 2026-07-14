# Labs — Cloud on Your Terms

You are going to build a small but real cloud platform on your own laptop: an immutable
Kubernetes OS, eBPF networking, GitOps delivery, database- and storage-as-a-service,
a self-service platform API, and (if you're fast) serverless, in-cluster CI, a developer
portal, and an event-driven picture pipeline that ties it all together. Everything keeps
working when you leave the building — that's the point. (From module 08 on, your platform
even shows its own progress: the Cloudbox Console's **Workshop** page at
http://localhost:30600/workshop is a live dashboard of which modules your cluster has
reached.)

## Module overview

| # | Module | Time | Type | Outcome (the visible win) |
|---|--------|------|------|---------------------------|
| 00 | [Setup & pre-flight](00-setup/) | before / first 15 min | gate | `./scripts/install.sh --check` is all green, images pre-pulled |
| 01 | [Your own cloud: Talos + Cilium](01-cluster/) | 35 min | core | 2 Kubernetes nodes Ready on eBPF networking — with no SSH and no kube-proxy anywhere |
| 02 | [GitOps: Gitea + ArgoCD](02-gitops/) | 35 min | core | You push a commit to *your cluster's own git server* and watch it materialize |
| 03 | [Data services: Postgres + S3](03-data/) | 35 min | core | `psql` into a database you provisioned via git; a presigned S3 URL that works |
| 04 | [Self-service: Crossplane v2](04-self-service/) | 35 min | core | One 10-line YAML claim → database + bucket appear |
| 05 | [Debug it (with or without AI)](05-debug-with-ai/) | 25 min | core | You found the seeded fault — and proved your (or your AI's) diagnosis against live state |
| 06 | [Serverless: Knative](06-serverless/) | stretch | self-paced | `curl` cold-starts a pod from zero, then it scales back to zero |
| 07 | [In-cluster CI: Workflows + BuildKit + Zot](07-ci/) | stretch | demo + self-paced | An image built *inside* your cluster, pushed to *your* registry, running as a pod |
| 08 | [Portal: the Cloudbox Console](08-portal/) | stretch | self-paced + demo | Create a database through a portal *you can read the source of* — plus a Backstage presenter demo |
| 09 | [Capstone: the picture pipeline](09-capstone/) | stretch | self-paced finale | Upload a photo → a resizer that didn't exist scales from zero → thumbnail, metadata, and the whole chain as one trace |

Core = 00–05. Stretch modules are for the fast 20% and for home; the core path never
depends on them — but they build on each other: 09 (capstone) needs 06 and 08, and 08's
star task needs 04's platform API. `./scripts/catch-up.sh <module>` bridges any gap.

## How every module works

Each module directory contains:

- **`README.md`** — states the *outcome*, not the steps. It tells you what must be true at
  the end and roughly where to look. It does **not** hand you 12 commands to paste.
- **Layered hints** — collapsed `<details>` blocks, escalating from a guiding question to
  the exact command. Open as many as you need; hints are free and nobody is counting.
  The last block is always the full solution — using it is fine, *understanding* it is required.
- **`verify.sh`** — the contract. Run it from the module directory at any time:

  ```bash
  ./verify.sh
  ```

  It performs many small checks against your *running cluster* (never against your files),
  prints ✅ per passing check and `❌ FAIL: <what's wrong and where to look>` per failing
  one, and exits 0 only when the module's outcome is fully true. Green verify = module done.
- **`solve.sh`** — the exact full-solution commands, runnable end-to-end. Designed for
  CI regression against `verify.sh` (job tracked in issue #10), and for you if you want
  to fast-forward.

Fallen behind? `./scripts/catch-up.sh <module>` force-pushes the canonical end-state of
that module to your in-cluster Gitea and lets ArgoCD converge (see [`solutions/`](../solutions/)).

## AI assistants are welcome

Using Claude Code, Copilot, kubectl-ai, or any other assistant is explicitly fine in every
module — we designed for it. The goal was never "typed the commands yourself"; it is a
running platform **plus** your ability to explain it. Two house rules:

1. `verify.sh` and the explain-back are the finish line, not the last command.
2. When an assistant tells you something about *your* cluster, check it against the
   cluster before acting on it. Module 05 exists to make that instinct permanent.

## Explain-backs

At the end of each module: two minutes, tell your neighbor **why** it works (each README
has a suggested prompt). An AI-generated fix you can't explain isn't done yet.

## Getting help in the room

- 🟩 **Green sticky note** on your screen — "I'm fine / done".
- 🟥 **Red/pink sticky note** — "stuck, please come by"; keep working on something else,
  a helper will find you. No hand-raising required.
- Pair freely. If your laptop fails pre-flight, pair up or use the devcontainer/Codespaces
  lifeboat (see [module 00](00-setup/)).
- When the room drifts apart, the presenter walks the solution on screen to re-sync —
  that's normal, not falling behind.
