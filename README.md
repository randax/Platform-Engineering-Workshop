# Cloud on Your Terms: Building Your Own Cloud-Native Platform

What happens when you can no longer trust your cloud provider's pricing, jurisdiction, or
roadmap? You build your own. This is the workshop repo for JavaZone 2026: four hands-on
hours, a complete cloud-native platform on your own laptop, all open source, all pinned,
and still running after you leave the room. Labs, solutions and scripts are public, so you
can finish at home.

## What we're building

A two-node Talos Linux cluster on your laptop, with a git server and a GitOps engine
running *inside* it. Everything else arrives the same way: capabilities live as ArgoCD
`Application` manifests in `gitops/catalog/`, and you turn one on by copying it into
`gitops/apps/`, committing, and pushing to your own in-cluster Gitea. Edit, push,
converge, all day, never touching GitHub or the conference WiFi.

Kubernetes, GitOps, a managed database, S3-compatible storage, a self-service
infrastructure API, serverless, in-cluster CI, observability and a portal, delivered by
the end of the day. The full component list and why each one beat its alternative are in
**[docs/STACK.md](docs/STACK.md)**.

## Before the conference

Conference WiFi carries keystrokes, not gigabytes: setup pulls roughly 7.5 GB of images
(7.7 GB on x86-64), so run it at home. You need Docker (Desktop, OrbStack or docker-ce)
with at least 10 GB and 4 CPUs, unless you use tbx, which needs none. On Apple Silicon,
decide about tbx *before* step 2: it warms images for the substrate you have at that
moment, and installing the helper afterwards downloads them twice
([docs/SUBSTRATES.md](docs/SUBSTRATES.md)).

```bash
git clone https://github.com/randax/Platform-Engineering-Workshop.git
# (will be renamed to jz-2026-platform-engineering — the old URL will redirect)
cd Platform-Engineering-Workshop

./scripts/dev-setup.sh   # 1. pinned CLI tools, via mise. Say yes to the shell hook: it
                         #    points KUBECONFIG at ~/.kube/cloudbox.conf, this workshop's
                         #    cluster and nothing else
mise run init            # 2. pre-pull all pinned images (~7.5 GB, be patient)
mise run preflight       # 3. prints ✅/❌ for everything
```

**All green means you are done.** Otherwise the output names the fix, and the
[devcontainer lifeboat](#plan-b-devcontainer--codespaces) covers what cannot be fixed.
Broken prereqs are our bug, not yours: open an issue and we will fix it before the day.
Bring your power supply. You do not build the cluster here; that happens in the room
([Get started](#get-started)).

Steps 2 and 3 are mise tasks, like every command below (`mise tasks` lists them all, and
the scripts they run live in `scripts/`). Step 1 stays a script because it is what
installs mise. Details on the kubeconfig pin are in
[docs/SUBSTRATES.md](docs/SUBSTRATES.md#your-kubeconfig).

## Get started

We run this together at the venue; it also works at home, offline, once the images are
pre-pulled and the Helm charts are vendored, and they are, in `scripts/manifests/`
(a registry mirror the nodes pull through, [detail](docs/SUBSTRATES.md#the-offline-story)).

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

The cluster runs on **Talos-in-Docker** (everyone, by default) or on **tbx**
([talos-box](https://github.com/randax/talos-box)) real Talos VMs (Apple Silicon macOS, or Linux with KVM, and only if you install its privileged
helper). You do not choose: the scripts detect it, `mise run preflight` prints which you
will get, and every module after 01 is identical on both. Force it with
`CLOUDBOX_SUBSTRATE=docker` or `=tbx`, or pin it for the machine as shown in
[Get started](#get-started).

**[docs/SUBSTRATES.md](docs/SUBSTRATES.md)** has the rest: the comparison table, the tbx
helper install and its macOS kernel-panic warning, hypervisor selection, what writes to
`/etc/hosts` and what happens if you decline the password, and the kind lifeboat.

## Platform support matrix

16 GB RAM, 4 cores and 40 GB free is the floor on both substrates (on Docker, with at
least 10 GB and 4 CPUs given to Docker itself); 32 GB is comfortable, and the full
platform idles at roughly 8 GB inside the cluster. Details, and what each substrate buys
you, are in [docs/SUBSTRATES.md](docs/SUBSTRATES.md#hardware).

| Platform | Substrate | Support |
|---|---|---|
| macOS, Apple Silicon | tbx (Docker if `tbx doctor` fails) | fully supported |
| Linux, amd64/arm64 with KVM | tbx (Docker if `tbx doctor` fails) | fully supported |
| macOS, Intel | Docker | fully supported |
| Windows via WSL2 | Docker | best-effort; pair up if it fights you |
| GitHub Codespaces / devcontainer | Docker | the lifeboat, tested weekly in CI |

On Linux, watch out for firewalld/nftables interference on either substrate.

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

## License

Apache License 2.0, see [LICENSE](LICENSE). Take it, fork it, run your cloud on your terms.
