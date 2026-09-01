# Labs: Cloud on Your Terms

You are going to build a small but real cloud platform on your laptop: an immutable
Kubernetes OS, eBPF networking, GitOps delivery, database- and storage-as-a-service,
a self-service platform API, and, if you're fast, serverless, in-cluster CI, a developer
portal, and an event-driven picture pipeline. Everything keeps working when you leave
the building. That's the point. From module 08 on, the Cloudbox Console's Workshop page
at http://portal.cloudbox.k8s.test/workshop shows live which modules your cluster has
reached.

## Module overview

| # | Module | Time | Type | Outcome (the visible win) |
|---|--------|------|------|---------------------------|
| 00 | [Setup & pre-flight](00-setup/) | before / first 15 min | gate | `mise run preflight` is all green, images pre-pulled |
| 01 | [Your own cloud: Talos + Cilium](01-cluster/) | 35 min | core | 2 Kubernetes nodes Ready on eBPF networking, with no SSH and no kube-proxy anywhere |
| 02 | [GitOps: Gitea + ArgoCD](02-gitops/) | 35 min | core | You push a commit to *your cluster's own git server* and watch it materialize |
| 03 | [Data services: Postgres + S3](03-data/) | 35 min | core | `psql` into a database you provisioned via git; a presigned S3 URL that works |
| 04 | [Self-service: Crossplane v2](04-self-service/) | 35 min | core | A name and a size in YAML → database + bucket appear |
| 05 | [Debug it (with or without AI)](05-debug-with-ai/) | 25 min | core | You took seeded faults to a proven root cause, checking your (or your AI's) diagnosis against live state |
| 06 | [Serverless: Knative](06-serverless/) | stretch | self-paced | `curl` cold-starts a pod from zero, then it scales back to zero |
| 07 | [In-cluster CI: Workflows + BuildKit + Zot](07-ci/) | stretch | demo + self-paced | An image built *inside* your cluster, pushed to *your* registry, running as a pod |
| 08 | [Portal: the Cloudbox Console](08-portal/) | stretch | self-paced + demo | Create a database through a portal *you can read the source of*, plus a Backstage presenter demo |
| 09 | [Capstone: the picture pipeline](09-capstone/) | stretch | self-paced finale | Upload a photo → a resizer that didn't exist scales from zero → thumbnail, metadata, and the whole chain as one trace |
| 10 | [Day-2 operations: roll back a bad release](10-day2-ops/) | stretch | self-paced | You found a bad release, proved the diagnosis, and reverted it in git, the only fix that sticks; kagent can assist |

Core = 00–05. Stretch modules are for the fast 20% and for home. The core path never
depends on them, but they build on each other: 09 needs 03, 06 and 08, 08's main task needs
04's platform API, and 10 only needs 02.

## How every module works

- **`README.md`** states the outcome: what must be true at the end, and roughly where
  to look. Not 12 commands to paste.
- **Hints** in collapsed `<details>` blocks escalate from a guiding question to the
  exact command. Open as many as you need; nobody is counting. The last one is always
  the full solution. Using it is fine, understanding it is required.
- **`verify.sh`** is the contract. Run it from the module directory at any time. It
  checks your *running cluster*, never your files, prints ✅ per pass and
  `❌ FAIL: <what and where>` per failure, and exits 0 only when the outcome is true.
  Green verify = module done.
- **`solve.sh`** is the full solution, runnable end-to-end.
- **Explain-back**: two minutes at the end of each module, tell your neighbor why it
  works (each README suggests a prompt). A fix you can't explain isn't done yet.
- Fallen behind? `mise run catch-up <module>` force-pushes that module's canonical
  end-state to your in-cluster Gitea and lets ArgoCD converge
  (see [`solutions/`](../solutions/)).

## AI assistants are welcome

Claude Code, Copilot, kubectl-ai, anything you like, in every module. We designed for
it. The finish line is a green `verify.sh` plus the explain-back, not the last command.
And when an assistant tells you something about *your* cluster, check it against the
cluster before acting on it. Module 05 exists to make that instinct permanent.

## Getting help in the room

- Green sticky note on your screen means "I'm fine". Red means "stuck, please come by";
  keep working on a hint layer or with a neighbor while a presenter sweeps over.
- Pair freely. If your laptop fails pre-flight, pair up or use the
  devcontainer/Codespaces lifeboat ([module 00](00-setup/)).
- When the room drifts apart, the presenter walks the solution on screen to re-sync.
  That's normal, not falling behind.
- Something is broken in a way that isn't yours to fix — a script, a lab, a pinned
  image? `mise run debug` (or `mise run debug <module>`) writes one redacted file with
  everything we would ask you for: platform, tool versions, cluster state, the logs of
  whatever isn't running, and the module's `verify.sh` output. It sends nothing.
  Paste it into the [help form](https://github.com/randax/Platform-Engineering-Workshop/issues/new?template=workshop-help.yml)
  — during the workshop or on the train home.
