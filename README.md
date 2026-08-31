# Cloud on Your Terms: Building Your Own Cloud-Native Platform

What happens when you can no longer trust your cloud provider's pricing, jurisdiction, or
roadmap? In four hands-on hours you build the answer on your own laptop: a complete
cloud-native platform (Kubernetes, GitOps, databases-as-a-service, object storage,
self-service infrastructure), all open source, all pinned, all still working after you leave
the room. The full picture: [What we're building](#what-were-building).

## Workshop facts

| | |
|---|---|
| **Conference** | JavaZone 2026, Sept 2–3, NOVA Spektrum, Lillestrøm |
| **Workshop day** | The day before the main conference (see the JavaZone program for exact day and venue) |
| **Duration** | 240 minutes (4 hours), hands-on |
| **Speakers** | Hans Kristian Flaatten, Øyvind Randa |
| **Repo** | Everything is public: labs, solutions, scripts. Finish at home if you want. |

## Before the conference

Conference WiFi carries keystrokes, not gigabytes; setup downloads roughly 7.5 GB of
container images (7.7 GB on x86-64). **Run these three steps at home, on a network you
trust:**

Install Docker first (Docker Desktop, OrbStack or docker-ce): step 2 needs it to run the
image mirror, and step 3 checks it has at least 10 GB and 4 CPUs. The exception is a
machine using tbx, which needs no Docker at all.

```bash
git clone https://github.com/randax/Platform-Engineering-Workshop.git
# (will be renamed to jz-2026-platform-engineering — the old URL will redirect)
cd Platform-Engineering-Workshop

./scripts/dev-setup.sh        # 1. install the pinned CLI tools, via mise
mise run init                 # 2. pre-pull all pinned images (~7.5 GB, be patient)
mise run preflight            # 3. preflight: prints ✅/❌ for everything
```

On Apple Silicon macOS, decide about tbx **before** step 2. Step 2 warms images for the
substrate you have at that moment, so installing the tbx helper afterwards means
downloading them again. See [docs/SUBSTRATES.md](docs/SUBSTRATES.md).

**If step 3 is all green, you are done.** If not, the output names what to fix; if it cannot
be fixed, the [devcontainer lifeboat](#plan-b-devcontainer--codespaces) has you covered.
Bring your laptop and its power supply.

You do not create the cluster at home: these steps install tools and download images; the
cluster is built in the room ([Get started](#get-started)). Step 1 offers to hook mise into
your shell; say yes ([what that pins](#your-kubectl-gets-a-workshop-only-kubeconfig)).
Steps 2–3, like every command below, are mise tasks (`mise tasks` lists them all; the
underlying scripts live in `scripts/`); step 1 stays a script because it is what installs
mise in the first place.

## Get started

We run this together at the venue; it also works at home, offline, once the images are
pre-pulled and the Helm charts are vendored, and they are, in `scripts/manifests/`
([the offline story](#the-offline-story)).

The cluster runs on one of two substrates, real Talos VMs via tbx or Talos-in-Docker; the
scripts detect which your machine supports and record the answer in `~/.cloudbox/substrate`,
so every later script agrees. To pin the choice for this machine instead:

```bash
mise set --file mise.local.toml CLOUDBOX_SUBSTRATE=docker    # or tbx
```

Comparison table, tbx helper install, record semantics: [docs/SUBSTRATES.md](docs/SUBSTRATES.md).

```bash
mise run cluster:create     # Talos cluster (tbx VMs or Docker) + Cilium
mise run gitops:bootstrap   # in-cluster Gitea + ArgoCD
mise run gitops:seed        # seed your cloud's git with the platform tree
```

On the Docker substrate, `mise run cluster:create` asks for your password once, at the very
end: the workshop's only sudo, writing hostnames into `/etc/hosts`
([why, and what if you decline](docs/SUBSTRATES.md#hostnames-on-the-docker-substrate)).

That is a working platform; the [labs](#lab-overview) take it from here. Fell behind or
broke something interesting? `mise run catch-up <module>` force-pushes that module's
canonical state to your Gitea and lets ArgoCD converge. If neither substrate cooperates,
`mise run cluster:fallback` builds a [kind lifeboat](docs/SUBSTRATES.md#the-kind-lifeboat) meeting the same
contract. Everything below is reference.

## What we're building

A two-node Talos Linux Kubernetes cluster on your laptop, with an in-cluster git server and
a GitOps engine delivering the entire platform on top: real VMs via
[talos-box](https://github.com/randax/talos-box) where your machine supports it, Docker
containers everywhere else.

```text
your laptop
└── talos-box VMs, or Docker (≥10 GB allocated)
    └── Talos v1.13.8 cluster (1 control plane + 1 worker)
        ├── Cilium 1.20 (eBPF CNI + shared ingress)
        ├── Gitea (in-cluster git — this is your cloud's git server)
        ├── ArgoCD v3.5 ── app-of-apps w/ sync waves ──────┐
        ├── CloudNativePG + demo Postgres                  │ everything below
        ├── RustFS (S3-compatible object storage)          │ is delivered as
        ├── Crossplane v2 (self-service compositions)      │ ArgoCD apps from
        ├── Knative Serving + Kourier          (stretch)   │ the in-cluster
        ├── Argo Workflows + BuildKit + Zot    (stretch)   │ Gitea
        ├── NATS JetStream (durable messaging) (stretch)   │
        ├── Backstage (CNOE image)             (stretch)   │
        └── Victoria stack + OTel Collector    (on-demand) ┘
```

The all-day mechanic: capabilities are a catalog of ArgoCD `Application` manifests. Copy one
from `gitops/catalog/` into `gitops/apps/`, commit, push to *your own* in-cluster Gitea,
watch ArgoCD converge. Edit → push → converge. That's GitOps, and it never touches GitHub or
the conference WiFi.

On object storage: we use [RustFS](https://rustfs.com), an Apache-2.0 alternative to MinIO,
whose open-source community edition was discontinued in 2025–26 in favor of the proprietary
AIStor. Same S3 API, licence you can live with.

Every component is a deliberate choice against a rejected alternative: Talos over kubeadm,
Cilium over kube-proxy, in-cluster Gitea over GitHub, Crossplane v2 over Helm, the Victoria
stack over kube-prometheus-stack. Tradeoffs in **[docs/STACK.md](docs/STACK.md)**.

## The Cloudbox Console

The platform's front door: a bespoke **Go + htmx** portal, server-rendered and fully
**offline** (no CDN, one vendored `.js` file, no build step). A read-only ServiceAccount
token lets it read the Kubernetes API and surface everything you built (ArgoCD apps, CNPG
databases, Knative services), plus **per-component metrics, logs, and traces** from the
on-cluster OTel stack (VictoriaMetrics / VictoriaLogs / VictoriaTraces via the OTel
Collector). Light and dark themes, responsive down to a phone. Small enough to read over
coffee: [`apps/portal/`](apps/portal/). You build it in [module 08](lab/08-portal); it comes
fully alive in the [capstone](lab/09-capstone).

<p align="center">
  <img src="docs/screenshots/console-component-monitoring-dark.png" alt="Cloudbox Console, a component's Monitoring page: CPU/memory sparklines and a live log tail" width="49%" />
  <img src="docs/screenshots/console-components-dark.png" alt="Cloudbox Console, the Components health page, per-namespace status" width="49%" />
</p>

<p align="center"><em>Left: a component's Monitoring detail (CPU/memory sparklines, live log tail from the OTel stack). Right: the Components health page. Both dark mode; the console ships light + dark.</em></p>

All screenshots (desktop, mobile nav, the "enable observability" gated state, database
metrics): [docs/screenshots/](docs/screenshots/README.md).

## Substrates, in one paragraph

The cluster runs on **Talos-in-Docker** (everyone, by default) or on **tbx** real Talos
VMs (Apple Silicon macOS, or Linux with KVM, and only if you install its privileged
helper). You do not choose: the scripts detect it, `mise run preflight` prints which you
will get, and every module after 01 is identical on both. Force it with
`CLOUDBOX_SUBSTRATE=docker` or `=tbx`, or pin it for the machine as shown in
[Get started](#get-started).

**[docs/SUBSTRATES.md](docs/SUBSTRATES.md)** has the rest: the comparison table, the tbx
helper install and its macOS kernel-panic warning, hypervisor selection, what writes to
`/etc/hosts` and what happens if you decline the password, and the kind lifeboat.

## The offline story

The offline guarantee, on both substrates, is a registry mirror the nodes pull through: on
the Docker path a `cloudbox-mirror` container on port 5001, on the tbx path talos-box's own
mirror (`tbx cache warm` fills `~/.talosbox/cache` and tbxd serves it to the VMs at the
cluster gateway). On tbx, step 2 also warms the Talos disk image (`tbx cache pull`, 95 MB on
arm64, 204 MB on amd64); step 3 asserts a complete `disk.raw` is in `~/.talosbox/cache` and
grades the images with `tbx cache warm --check` (use `--check --deep` before you travel). At
the venue, `tbx mirror offline on` stops tbx's mirror fetching upstream, so a missing image
surfaces as a mirror miss rather than being quietly filled over the WiFi; the nodes keep
`skipFallback: false`, so the pull then goes direct, slowly and visibly.

One trade-off: tbx's store serves VMs only, so on a tbx laptop the Talos-in-Docker fallback
is **not** offline-ready unless you also run `CLOUDBOX_SUBSTRATE=docker mise run init` at
home (needs Docker, ~7.5 GB more).

## Your `kubectl` gets a workshop-only kubeconfig

Step 1 offers to hook [mise](https://mise.jdx.dev/) into your shell. **Say yes.** Besides
putting the pinned tools on your PATH, it makes `KUBECONFIG` point at
**`~/.kube/cloudbox.conf`** while you are inside this repo: this workshop's cluster and
nothing else, so tearing it down leaves nothing for `kubectl` to silently fall through to,
and your own contexts are never modified. `echo $KUBECONFIG` shows which file you are on.
Decline and everything lands in `~/.kube/config` as it always did; the workshop still works,
and the scripts refuse to touch a non-workshop context either way. Just don't do half of
each: scripts through `mise run` / `mise exec` plus bare `kubectl` in a shell that never got
the pin puts your cluster and your terminal on two different files.
`./scripts/install.sh --check` tells you which side you are on.

## Hardware: honest numbers

| | tbx (real Talos VMs) | Docker (Talos-in-Docker) |
|---|---|---|
| Minimum | 16 GB RAM, 4 cores, 40 GB free | 16 GB RAM with **≥10 GB and ≥4 CPUs to Docker**, 40 GB free |
| Comfortable | 32 GB | 32 GB |
| What you get | real `LoadBalancer` VIPs, a real L2 segment | the same labs, the same URLs, via published ports |

The full platform idles at roughly 8 GB inside the cluster; 16 GB machines fit, but close
your Electron zoo. On Docker: OrbStack, or a Docker Desktop with a raised memory limit; WSL2
users raise it in `.wslconfig`. On tbx the VM sizes are pins (`TBX_CP_MEMORY` /
`TBX_WORKER_MEMORY` in `scripts/versions.env`): a boot ceiling, not a permanent reservation.
talos-box balloons memory back out of a running node when the host comes under pressure,
which keeps the laptop alive and means a hungry browser can shrink your cluster mid-module.
Close the zoo anyway.

## Platform support matrix

| Platform | Substrate | Support |
|---|---|---|
| macOS, Apple Silicon | tbx (Docker if `tbx doctor` fails) | fully supported |
| Linux, amd64/arm64 with KVM | tbx (Docker if `tbx doctor` fails) | fully supported |
| macOS, Intel | Docker | fully supported |
| Windows via WSL2 | Docker | best-effort; pair up if it fights you |
| GitHub Codespaces / devcontainer | Docker | the lifeboat, tested weekly in CI |

On Linux, watch out for firewalld/nftables interference on either substrate.

## Lab overview

Labs live in `lab/`. Each module states an **outcome** ("make your cluster reach state X"),
ships a `verify.sh` that checks it against the live cluster, and layers hints from gentle
nudge to full solution. You choose how much to open.

| Module | Topic | Type | Visible win |
|---|---|---|---|
| [00-setup](lab/00-setup) | Preflight & environment | core | `install.sh --check` all green |
| [01-cluster](lab/01-cluster) | Talos + Cilium: you now own a cloud | core | nodes `Ready`, Cilium green |
| [02-gitops](lab/02-gitops) | Gitea + ArgoCD, bootstrap the platform tree | core | edit → push → watch ArgoCD converge |
| [03-data](lab/03-data) | CloudNativePG + RustFS via GitOps | core | `psql` into your own DBaaS; presigned URL works |
| [04-self-service](lab/04-self-service) | Crossplane v2 compositions | core | one YAML → whole app stack appears |
| [05-debug-with-ai](lab/05-debug-with-ai) | Fault injection + AI-assisted diagnosis | core | found and fixed the seeded fault |
| [06-serverless](lab/06-serverless) | Knative Serving + Kourier | stretch | curl a scale-from-zero URL |
| [07-ci](lab/07-ci) | Argo Workflows + BuildKit + Zot | stretch | in-cluster image build goes green |
| [08-portal](lab/08-portal) | Cloudbox Console: a portal you can read (+ Backstage demo) | stretch | create a database from a form, prove it with kubectl |
| [09-capstone](lab/09-capstone) | Capstone: event-driven picture pipeline (Knative Eventing) | stretch | upload a photo → watch a resizer scale from zero → thumbnail + trace |
| [10-day2-ops](lab/10-day2-ops) | Day-2 operations: roll back a bad release | stretch | `git revert` as the durable fix, with kagent optionally assisting the diagnosis |

Core modules are the plan. Stretch modules are for the fast 20%, and for your couch
afterwards. Canonical end-states live in `solutions/`.

## Using AI assistants

**Yes. Please.** Claude Code, Copilot, kubectl-ai, whatever you run: point it at your
cluster. The labs are outcomes, not command lists, because copying 12 commands (yourself or
via an LLM) teaches nothing; the goal is a running platform and the mental model, not the
typing. One warning shot: module 05 includes a fault where the obvious AI diagnosis is
plausible and wrong. Verifying what an agent tells you against the live system is the 2026
skill, and we'll practice it.

**The house style: your assistant is a tutor, not a chauffeur.** This repo's instructions
(`CLAUDE.md` / `AGENTS.md`) ask coding agents to *coach* during the workshop (explain, point
at the next hint layer, debug your environment with you) and to decline to simply do the
labs for you. It's advisory: you can delete the file or talk your agent past it, except that
the only thing you'd take home from a workshop your agent did is a warm laptop. One
deliberate carve-out: **environment and tooling failures are not the lesson.** Docker won't
start, a mise shim misbehaves, a download died halfway? Sic your agent on those with
everything it has.

## Plan B: devcontainer / Codespaces

If `mise run preflight` won't go green on your machine, don't burn workshop time on it. This
repo ships a [devcontainer](.devcontainer/devcontainer.json) with Docker-in-Docker and all
tools preinstalled, the exact same workshop content:

- **GitHub Codespaces**: Code → Create codespace on this repo. Pick a machine with
  **4 cores / 16 GB RAM** or larger, then run the same three prework steps inside it.
- **Locally**: any editor that speaks the [Dev Containers spec](https://containers.dev)
  (VS Code, JetBrains, `devcontainer` CLI), though if Docker works locally you likely don't
  need the lifeboat.

**One thing differs in Codespaces: how you open a service.** Everywhere else the workshop's
URLs are hostnames (`http://gitea.cloudbox.k8s.test`). A codespace's browser is not on the
machine the cluster runs on; it reaches the container through
`https://<codespace>-<port>.app.github.dev`, which sends whatever `Host` header GitHub
chooses, and the platform's ingress routes **by hostname**, so the forwarded port-80 URL
404s on a healthy cluster. Use the **Ports tab** instead: the devcontainer forwards a
NodePort per service, each row opening the right one directly, no `Host` header involved.

| Ports tab entry | Service |
|---|---|
| NodePort 30300 | Gitea (in-cluster git) |
| NodePort 30080 | ArgoCD |
| NodePort 30600 | Cloudbox Console |
| NodePort 30030 | Grafana |
| NodePort 30900 | RustFS S3 |
| NodePort 30500 | Zot registry |
| NodePort 31080 | your apps (Kourier); needs a `Host` header, so `curl` it from the terminal |

Inside the codespace's own terminal the hostnames work normally (`curl` and the labs'
`verify.sh` scripts resolve them from the container's `/etc/hosts`); only the browser needs
the Ports tab.

Codespaces runs in Microsoft's cloud. A pragmatic irony for a sovereignty workshop, and
exactly why it's the lifeboat and not the boat.

## Workshop leaders

### Øyvind Randa

Software Architect at NextGentel and Lead Organizer for GDG Bergen

### Hans Kristian Flaatten

Platform maker, dream awaker | CNCF Ambassador | Google Developer Expert | Grafana Champion
| Co-host of Plattformpodden | Platform Engineer in Norwegian Government | Open Source
Maintainer

## Getting help

- **Before the workshop:** open an issue on this repo; broken prereqs are our bug, not yours.
- **During the workshop:** sticky notes signal silently (red = stuck); the two presenters cover the room, and recurring questions get answered to everyone.
- **After:** everything here is public and pinned. The `javazone-2026` tag will mark the state we shipped.

## License

Apache License 2.0, see [LICENSE](LICENSE). Take it, fork it, run your cloud on your terms.
