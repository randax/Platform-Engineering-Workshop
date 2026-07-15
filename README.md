# Cloud on Your Terms: Building Your Own Cloud-Native Platform

What happens when you can no longer trust your cloud provider — or its pricing, its
jurisdiction, or its roadmap? In this workshop you build the answer: a complete
cloud-native platform — Kubernetes, GitOps, databases-as-a-service, object storage,
self-service infrastructure — running entirely on hardware you own. Your laptop becomes
the cloud. Everything is open source, everything is pinned, and everything keeps working
after you leave the room. That running platform, and the mental model of how it fits
together, is the one thing a video or an AI assistant can't give you.

## Workshop facts

| | |
|---|---|
| **Conference** | JavaZone 2026, Sept 2–3, NOVA Spektrum, Lillestrøm |
| **Workshop day** | The day before the main conference (see the JavaZone program for exact day and venue) |
| **Duration** | 240 minutes (4 hours), hands-on |
| **Speakers** | Hans Kristian Flaatten, Øyvind Randa |
| **Repo** | Everything is public — labs, solutions, scripts. Finish at home if you want. |

## What we're building

A two-node Talos Linux Kubernetes cluster inside Docker on your laptop, with an
in-cluster git server and a GitOps engine delivering the entire platform on top:

```text
your laptop
└── Docker (≥10 GB allocated)
    └── Talos v1.13.6 cluster (1 control plane + 1 worker)
        ├── Cilium 1.19 (eBPF CNI)
        ├── Gitea (in-cluster git — this is your cloud's git server)
        ├── ArgoCD v3.4 ── app-of-apps w/ sync waves ──────┐
        ├── CloudNativePG + demo Postgres                  │ everything below
        ├── RustFS (S3-compatible object storage)          │ is delivered as
        ├── Crossplane v2 (self-service compositions)      │ ArgoCD apps from
        ├── Knative Serving + Kourier          (stretch)   │ the in-cluster
        ├── Argo Workflows + BuildKit + Zot    (stretch)   │ Gitea
        ├── NATS JetStream (durable messaging) (stretch)   │
        ├── Backstage (CNOE image)             (stretch)   │
        └── Victoria stack + OTel Collector    (on-demand) ┘
```

The mechanic you'll use all day: the platform capabilities live as a catalog of ArgoCD
`Application` manifests. You enable a capability by copying its manifest from
`gitops/catalog/` into `gitops/apps/`, committing, and pushing to *your own* in-cluster
Gitea — then you watch ArgoCD converge. Edit → push → converge. That's GitOps, and it
never touches GitHub or the conference WiFi.

The platform even gets its own front door: the **Cloudbox Console**, a bespoke Go+htmx
portal (source in `apps/`, small enough to read over coffee) that surfaces everything you
built and lets you self-service a database from a form.

On object storage: we use [RustFS](https://rustfs.com), an Apache-2.0 alternative to
MinIO, whose open-source community edition was discontinued in 2025–26 in favor of the
proprietary AIStor. Same S3 API, licence you can live with.

## Prerequisites — do this BEFORE the conference

Conference WiFi carries keystrokes, not gigabytes. The setup downloads 15–20 GB of
container images. **Run all three steps at home, on a network you trust:**

```bash
git clone https://github.com/randax/Platform-Engineering-Workshop.git
# (will be renamed to jz-2026-platform-engineering — the old URL will redirect)
cd Platform-Engineering-Workshop

./scripts/dev-setup.sh        # 1. install the pinned CLI tools (via mise)
./scripts/cloudbox-init.sh    # 2. pre-pull all pinned images (15–20 GB — be patient)
./scripts/install.sh --check  # 3. preflight: prints ✅/❌ for everything
```

If step 3 is all green, you're done. If it isn't, the output tells you what to fix — and
if it can't be fixed, the [devcontainer lifeboat](#plan-b-devcontainer--codespaces) below
has you covered. Bring your laptop and its power supply.

### Hardware — honest numbers

| | Minimum | Recommended |
|---|---|---|
| RAM | **16 GB** (≥10 GB allocatable to Docker) | 32 GB |
| CPU | 4 cores | more |
| Free disk | 40 GB | more |

The full platform idles at roughly 8 GB inside the cluster. On 16 GB machines it fits,
but close your Electron zoo. macOS users: OrbStack or a Docker Desktop with a raised
memory limit. WSL2 users: raise the limit in `.wslconfig`.

### Platform support matrix

| Platform | Status |
|---|---|
| macOS (Apple Silicon) | ✅ Fully supported |
| macOS (Intel) | ✅ Fully supported |
| Linux | ✅ Fully supported (watch out for firewalld/nftables interference) |
| Windows (WSL2) | ⚠️ Best effort — it should work, but it's our least-tested platform. If it fights you, pair up with a neighbor or use the devcontainer lifeboat. |

## At the venue

You'll run these together with us — no need to run them at home (but you can; the whole
workshop works offline once the images are pre-pulled and the Helm charts are vendored —
they are, in `scripts/manifests/`):

```bash
./scripts/create-cluster.sh     # Talos-in-Docker cluster + Cilium
./scripts/bootstrap-gitops.sh   # in-cluster Gitea + ArgoCD
./scripts/seed-gitea.sh         # seed your cloud's git with the platform tree
```

Fell behind or broke something interesting? `./scripts/catch-up.sh <module>` force-pushes
the canonical state for that module to your Gitea and lets ArgoCD converge — scripted
state, not hope. If Talos-in-Docker won't cooperate on your machine,
`./scripts/kind-fallback.sh` gives you a kind+Cilium cluster and you continue from
module 2 onward.

## Lab overview

Labs live in `lab/`. Each module states an **outcome** ("make your cluster reach state
X"), ships a `verify.sh` that checks it against the live cluster, and layers hints from
gentle nudge to full solution — you choose how much to open.

| Module | Topic | Type | Visible win |
|---|---|---|---|
| [00-setup](lab/00-setup) | Preflight & environment | core | `install.sh --check` all green |
| [01-cluster](lab/01-cluster) | Talos + Cilium — you now own a cloud | core | nodes `Ready`, Cilium green |
| [02-gitops](lab/02-gitops) | Gitea + ArgoCD, bootstrap the platform tree | core | edit → push → watch ArgoCD converge |
| [03-data](lab/03-data) | CloudNativePG + RustFS via GitOps | core | `psql` into your own DBaaS; presigned URL works |
| [04-self-service](lab/04-self-service) | Crossplane v2 compositions | core | one YAML → whole app stack appears |
| [05-debug-with-ai](lab/05-debug-with-ai) | Fault injection + AI-assisted diagnosis | core | found and fixed the seeded fault |
| [06-serverless](lab/06-serverless) | Knative Serving + Kourier | stretch | curl a scale-from-zero URL |
| [07-ci](lab/07-ci) | Argo Workflows + BuildKit + Zot | stretch | in-cluster image build goes green |
| [08-portal](lab/08-portal) | Cloudbox Console — a portal you can read (+ Backstage demo) | stretch | create a database from a form, prove it with kubectl |
| [09-capstone](lab/09-capstone) | Capstone: event-driven picture pipeline (Knative Eventing) | stretch | upload a photo → watch a resizer scale from zero → thumbnail + trace |

Core modules are the plan; stretch modules are for the fast 20% — and for your couch
afterwards. Canonical end-states live in `solutions/`.

## Using AI assistants

**Yes. Please.** Claude Code, Copilot, kubectl-ai, whatever you run — point it at your
cluster. The labs are written as outcomes, not command lists, precisely because copying
12 commands (yourself or via an LLM) teaches nothing. The goal is a running platform and
the mental model of how it hangs together — not the typing.

One warning shot: module 05 includes a fault where the obvious AI diagnosis is plausible
and wrong. Verifying what an agent tells you against the live system is the 2026 skill,
and we'll practice it.

## Plan B: devcontainer / Codespaces

If `./scripts/install.sh --check` won't go green on your machine, don't burn workshop
time on it. This repo ships a [devcontainer](.devcontainer/devcontainer.json) with
Docker-in-Docker and all tools preinstalled — the exact same workshop content:

- **GitHub Codespaces**: Code → Create codespace on this repo. Pick a machine with
  **4 cores / 16 GB RAM** or larger, then run the same three prework scripts inside it.
- **Locally**: any editor that speaks the [Dev Containers spec](https://containers.dev)
  (VS Code, JetBrains, `devcontainer` CLI) — though if Docker works locally, you likely
  don't need the lifeboat.

Note that Codespaces runs in Microsoft's cloud — a pragmatic irony for a sovereignty
workshop, and exactly why it's the lifeboat and not the boat.

## Workshop leaders

### Øyvind Randa

Software Architect at NextGentel and Lead Organizer for GDG Bergen

### Hans Kristian Flaatten

Platform maker, dream awaker | CNCF Ambassador | Google Developer Expert | Grafana
Champion | Co-host of Plattformpodden | Platform Engineer in Norwegian Government |
Open Source Maintainer

## Getting help

- **Before the workshop:** open an issue on this repo — broken prereqs are our bug, not yours.
- **During the workshop:** helpers roam the room; sticky notes signal silently.
- **After:** everything here is public and pinned. `git tag javazone-2026` is the state we shipped.

## License

Apache License 2.0 — see [LICENSE](LICENSE). Take it, fork it, run your cloud on your terms.
