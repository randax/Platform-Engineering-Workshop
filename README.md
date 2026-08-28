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

A two-node Talos Linux Kubernetes cluster on your laptop — real VMs via
[talos-box](https://github.com/randax/talos-box) where your machine supports it, Docker
containers everywhere else — with an in-cluster git server and a GitOps engine delivering
the entire platform on top:

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

Every component was a deliberate choice against a rejected alternative — Talos over
kubeadm, Cilium over kube-proxy, in-cluster Gitea over GitHub, Crossplane v2 over Helm,
the Victoria stack over kube-prometheus-stack. The full "what we chose, what we rejected,
and the tradeoff" reference is in **[docs/STACK.md](docs/STACK.md)**.

## The Cloudbox Console

The platform's front door is a first-class thing, not an afterthought: a bespoke portal
built in **Go + htmx**, server-rendered and fully **offline** (no CDN, one vendored `.js`
file, no build step). It reads the Kubernetes API with a read-only ServiceAccount token
and surfaces everything you built — ArgoCD apps, CNPG databases, Knative services — plus
**per-component metrics, logs, and traces** pulled straight from the on-cluster OTel stack
(VictoriaMetrics / VictoriaLogs / VictoriaTraces via the OTel Collector). Light and dark
themes, responsive down to a phone. Small enough to read over coffee — the whole thing is
in [`apps/portal/`](apps/portal/).

<p align="center">
  <img src="docs/screenshots/console-component-monitoring-dark.png" alt="Cloudbox Console — a component's Monitoring page: CPU/memory sparklines and a live log tail" width="49%" />
  <img src="docs/screenshots/console-components-dark.png" alt="Cloudbox Console — the Components health page, per-namespace status" width="49%" />
</p>

<p align="center"><em>Left: a component's live Monitoring detail — CPU/memory sparklines and a log tail from the OTel stack. Right: the Components health page. Both shown in dark mode; the console ships light + dark.</em></p>

You build it in [module 08](lab/08-portal) and it comes fully alive in the
[capstone](lab/09-capstone). The full set of screenshots — desktop, mobile nav, the
"enable observability" gated state, database metrics — is in
[docs/screenshots/](docs/screenshots/README.md).

## Prerequisites — do this BEFORE the conference

Conference WiFi carries keystrokes, not gigabytes. The setup downloads roughly 7.5 GB of
container images (7.7 GB on x86-64). **Run steps 1–3 at home, on a network you trust:**

```bash
# 0. OPTIONAL, and only on Apple Silicon macOS or Linux with KVM: real Talos VMs.
#    Skip it and you get the Docker substrate, which runs the same workshop.
brew install randax/tap/tbx && sudo tbx system install && tbx doctor
#    (Linux: the release tarball + `sudo tbx system install`. mise cannot install
#     tbx yet — it is pinned in scripts/versions.env and mise.toml's comment.)

git clone https://github.com/randax/Platform-Engineering-Workshop.git
# (will be renamed to jz-2026-platform-engineering — the old URL will redirect)
cd Platform-Engineering-Workshop

./scripts/dev-setup.sh        # 1. install the pinned CLI tools (via mise)
./scripts/cloudbox-init.sh    # 2. pre-pull all pinned images (~7.5 GB — be patient)
./scripts/install.sh --check  # 3. preflight: prints ✅/❌ for everything
```

If step 3 is all green, you're done. If it isn't, the output tells you what to fix — and
if it can't be fixed, the [devcontainer lifeboat](#plan-b-devcontainer--codespaces) below
has you covered. Bring your laptop and its power supply.

**Docker is required on Talos-in-Docker only.** The offline story is a registry mirror
the nodes pull through: on the docker path a `cloudbox-mirror` container on port 5001, on
the tbx path talos-box's own mirror (`tbx cache warm` fills `~/.talosbox/cache`, tbxd
serves it to the VMs at the cluster gateway) — so a tbx laptop needs no Docker at all. On
the tbx path step 2 also warms the Talos disk image (`tbx cache pull`, 95 MB on arm64 /
204 MB on amd64), step 3 asserts a complete `disk.raw` is in `~/.talosbox/cache` and
grades the images with `tbx cache warm --check` (`--check --deep` before you travel), and
at the venue `tbx mirror offline on` makes a missing image fail loudly instead of quietly
reaching for the WiFi.
`install.sh --check` prints which substrate you will get, and — when it falls back to
Docker — the `tbx doctor` line that decided it.

### Your `kubectl` gets a workshop-only kubeconfig

Step 1 offers to hook [mise](https://mise.jdx.dev/) into your shell. **Say yes.** Besides
putting the pinned tools on your PATH, it makes `KUBECONFIG` point at
**`~/.kube/cloudbox.conf`** while you are inside this repo — a file that contains this
workshop's cluster and nothing else.

That is deliberate. You almost certainly arrive with a `~/.kube/config` full of real
clusters, and the workshop scripts create, patch and delete things in whatever cluster
`kubectl` currently points at. A separate file means tearing the workshop cluster down
leaves nothing for `kubectl` to silently fall through to. Your own contexts are never
modified, and `echo $KUBECONFIG` tells you which file you are on at any moment.

If you decline the activation, everything lands in `~/.kube/config` as it always did and
the workshop still works — the scripts refuse to touch a non-workshop context either way.
The one thing to avoid is doing half of each: running the scripts through `mise run` /
`mise exec` while typing bare `kubectl` in a shell that never got the pin, because then
your cluster and your terminal are looking at two different files.
`./scripts/install.sh --check` tells you which side you are on.

### Hardware — honest numbers

| | tbx (real Talos VMs) | Docker (Talos-in-Docker) |
|---|---|---|
| Minimum | 16 GB RAM, 4 cores, 40 GB free | 16 GB RAM with **≥10 GB and ≥4 CPUs to Docker**, 40 GB free |
| Comfortable | 32 GB | 32 GB |
| What you get | real `LoadBalancer` VIPs, a real L2 segment | the same labs, the same URLs, via published ports |

The full platform idles at roughly 8 GB inside the cluster. On 16 GB machines it fits,
but close your Electron zoo. On the Docker substrate: OrbStack, or a Docker Desktop with
a raised memory limit; WSL2 users raise it in `.wslconfig`. On tbx the VM sizes are pins
(`TBX_CP_MEMORY` / `TBX_WORKER_MEMORY` in `scripts/versions.env`) — they are the ceiling
each guest boots with, not a permanent reservation: talos-box balloons memory back out of
a running node when the host comes under pressure. That keeps the laptop alive; it also
means a hungry browser can shrink your cluster mid-module. Close the zoo anyway.

### Platform support matrix

| Platform | Substrate | Support |
|---|---|---|
| macOS, Apple Silicon | tbx (Docker if `tbx doctor` fails) | fully supported |
| Linux, amd64/arm64 with KVM | tbx (Docker otherwise) | fully supported on Docker; **tbx is best-effort at the pinned v0.1.1** |
| macOS, Intel | Docker | fully supported |
| Windows via WSL2 | Docker | best-effort — pair up if it fights you |
| GitHub Codespaces / devcontainer | Docker | the lifeboat, tested weekly in CI |

Both substrates run **the same labs, the same `verify.sh` scripts and the same URLs**. The
scripts pick for you and remember the choice in `~/.cloudbox/substrate`; override with
`CLOUDBOX_SUBSTRATE=docker` or `=tbx`. On Linux, watch out for firewalld/nftables
interference on either substrate.

The memory lasts as long as the cluster does: `destroy-cluster.sh` removes that file
along with the cluster it described, and the next `create-cluster.sh` decides again from
scratch. It prints the substrate it just forgot and the command that keeps it
(`CLOUDBOX_SUBSTRATE=<what it was> ./scripts/create-cluster.sh`) — worth using if you
chose that substrate deliberately, because detection will not know you did.
`catch-up.sh <module> --rebuild` carries it across for you.

**The override picks; it does not overrule what is already there.** Once a cluster has
been created, `~/.cloudbox/substrate` is a *record*, not a preference — and `create-cluster.sh`,
`destroy-cluster.sh`, `kind-fallback.sh`, `--refresh-endpoint` and
`install.sh --write-hosts`/`--add-hosts` all refuse, before touching anything, when the
substrate you are asking for is not the one this machine recorded. Changing substrates is
two commands and they say so:

```bash
CLOUDBOX_SUBSTRATE=tbx ./scripts/destroy-cluster.sh   # (or ./scripts/kind-fallback.sh --delete)
CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh
```

A machine with no record — a fresh laptop, CI — is unaffected: the override is simply the
answer there.

**Linux + tbx, the fine print.** Detection gates on `tbx doctor`, and at the pinned
v0.1.1 one of its Linux checks turns a *permission* problem into a verdict: with
`br_netfilter` active it runs `iptables -S FORWARD`, and an unprivileged shell's exit 4
becomes `FAIL inspect FORWARD policy` rather than "could not tell". On such a host
detection quietly falls back to Docker — which works, and is why this is best-effort
rather than broken. If you want the VMs anyway and you have checked the FORWARD policy
yourself, run `sudo iptables -S FORWARD` once to see the real answer and then force the
substrate: `CLOUDBOX_SUBSTRATE=tbx ./scripts/create-cluster.sh` (add
`CLOUDBOX_ALLOW_TBX_DRIFT=1` if you are on a newer tbx than the pin). Upstream fixed it
in `053aecb` — WARN with a sudo remediation — so this note retires with the first tbx
release that contains it.

**Half-installed tbx.** If `tbx` is on your PATH but its helper daemon is not running, the
docker path cannot ask it whether a `cloudbox` cluster exists there. It continues anyway
when this machine carries no trace of one (`~/.cloudbox/substrate`, `~/.cloudbox/cloudbox.tbx.yaml`
and `~/.talosbox/clusters/cloudbox` all absent — nothing it ever created can be running).
When a trace *is* present it stops rather than risk two clusters of the same name: fix tbx,
or set `CLOUDBOX_IGNORE_TBX=1` if you know those VMs are down.

**One catalog extra is amd64-only:** Backstage's CNOE image has no arm64 build, and a tbx
VM emulates nothing, so on Apple Silicon that stretch item needs the Docker substrate.
`install.sh --check` warns. Nothing on the core path is affected.

## At the venue

You'll run these together with us — no need to run them at home (but you can; the whole
workshop works offline once the images are pre-pulled and the Helm charts are vendored —
they are, in `scripts/manifests/`):

```bash
./scripts/create-cluster.sh     # Talos cluster (tbx VMs or Docker) + Cilium
./scripts/bootstrap-gitops.sh   # in-cluster Gitea + ArgoCD
./scripts/seed-gitea.sh         # seed your cloud's git with the platform tree
```

**On the Docker substrate, `create-cluster.sh` asks for your password once, at the very
end.** It is the only sudo in the workshop: Docker has no resolver, so the workshop
hostnames come from a marked `# cloudbox-begin` block in `/etc/hosts`, written via
`sudo tee`. See exactly what goes in with `./scripts/install.sh --print-hosts` (WSL2: the
same lines also belong in `C:\Windows\System32\drivers\etc\hosts`, edited as
Administrator). Decline the password and every `*.cloudbox.k8s.test` URL fails on a
perfectly healthy cluster — the cluster itself is fine and stays up, and
`./scripts/install.sh --write-hosts` writes the block whenever you are ready.
That is also the command to run if the names ever stop resolving: **WSL2 regenerates
`/etc/hosts` on every restart** unless you tell it not to (see `lab/00-setup`).
*Every* `./scripts/destroy-cluster.sh` on the Docker substrate *asks* to remove the block
again — not only `--purge-mirror`, which additionally forgets the extra names you added
with `--add-hosts`. It is one more sudo prompt, and you may decline it: the teardown
finishes either way and says which lines are still there. On the tbx substrate nothing touches `/etc/hosts` — talos-box's own
resolver answers the names.

Fell behind or broke something interesting? `./scripts/catch-up.sh <module>` force-pushes
the canonical state for that module to your Gitea and lets ArgoCD converge — scripted
state, not hope. If neither substrate will cooperate on your machine,
`./scripts/kind-fallback.sh` gives you a kind+Cilium cluster that meets the same
contract: the same vendored Cilium with the **same ingress values**, host port 80
mapped to the ingress, and the same marked `/etc/hosts` block — so every
`*.cloudbox.k8s.test` hostname works and **modules 02 onward are identical**. You
lose only the Talos content of module 1.

kind is not one of the two substrates — but it *is* a recorded identity. The script
writes `kind` into `~/.cloudbox/substrate`, which is what tells `install.sh --check`
to grade this machine with Docker semantics, fills the image mirror for the right
architecture, and makes `create-cluster.sh` and `destroy-cluster.sh` **refuse**
rather than build a second cluster over the lifeboat or delete its hostnames.
Tear it down with `./scripts/kind-fallback.sh --delete`, which deletes the kind
cluster, removes the `/etc/hosts` block it wrote (one sudo prompt, and you may
decline it — it then names the lines to delete by hand) and clears the identity.
It removes that block only when the identity says `kind`, so running it on a
Docker-substrate machine cannot take out a live cluster's names — and it clears the
identity only once the cluster is gone *and* the block is removed (or proven absent), so a
declined sudo leaves you able to retry rather than stranded with a block no command will
own. If the file is missing — a lifeboat taken before this existed — say so for the
session: `CLOUDBOX_SUBSTRATE=kind ./scripts/install.sh --check`. The same override works
for the teardown, `CLOUDBOX_SUBSTRATE=kind ./scripts/kind-fallback.sh --delete`, but there
it is honoured only against **kind-specific** proof: `kind get clusters` must list
`cloudbox`, or Docker must still hold containers labelled
`io.x-k8s.kind.cluster=cloudbox`. The `/etc/hosts` block is *not* proof — the docker
substrate writes an identical one, so accepting it would let an environment variable
delete a live Talos cluster's hostnames. Once the claim is proved, `kind` is written back
into `~/.cloudbox/substrate` immediately, so a retry after a declined sudo needs no
override at all. The teardown exits non-zero whenever anything is left, and it needs
Docker running (it asks the daemon for the containers) but neither `kind` nor `kubectl`
on `PATH`.

The one thing you give up is **module 01**: `lab/01-cluster/verify.sh` checks a Talos
cluster, so on the lifeboat it prints "not gradeable here" and exits 0 rather than
failing a cluster that is working as documented.

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

**The house style: your assistant is a tutor, not a chauffeur.** This repo ships
instructions (`CLAUDE.md` / `AGENTS.md`) that ask coding agents to *coach* during the
workshop — explain, point at the next hint layer, debug your environment with you — and
to decline to simply do the labs for you. Two honest notes about that. First, it's
advisory: you can delete the file or talk your agent past it, and nothing will stop you —
except that the only thing you'd take home from a workshop your agent did is a warm
laptop. Second, it has a deliberate carve-out: **environment and tooling failures are not
the lesson.** Docker won't start, a mise shim misbehaves, a download died halfway —
sic your agent on those with everything it has; yak-shaving is nobody's learning
objective. The platform concepts are.

## Plan B: devcontainer / Codespaces

If `./scripts/install.sh --check` won't go green on your machine, don't burn workshop
time on it. This repo ships a [devcontainer](.devcontainer/devcontainer.json) with
Docker-in-Docker and all tools preinstalled — the exact same workshop content:

- **GitHub Codespaces**: Code → Create codespace on this repo. Pick a machine with
  **4 cores / 16 GB RAM** or larger, then run the same three prework scripts inside it.
- **Locally**: any editor that speaks the [Dev Containers spec](https://containers.dev)
  (VS Code, JetBrains, `devcontainer` CLI) — though if Docker works locally, you likely
  don't need the lifeboat.

**One thing is different in Codespaces: how you open a service.** Everywhere else the
workshop's URLs are hostnames (`http://gitea.cloudbox.k8s.test`). In a codespace your
browser is not on the machine the cluster runs on — it reaches the container through
`https://<codespace>-<port>.app.github.dev`, which sends whatever `Host` header GitHub
chooses, and the platform's ingress routes **by hostname**. So the forwarded port-80 URL
finds no matching rule and 404s, on a cluster that is completely healthy.

Use the **Ports tab** instead. The devcontainer forwards a NodePort per service, and each
row opens the right one directly, no `Host` header involved:

| Ports tab entry | Service |
|---|---|
| NodePort 30300 | Gitea (in-cluster git) |
| NodePort 30080 | ArgoCD |
| NodePort 30600 | Cloudbox Console |
| NodePort 30030 | Grafana |
| NodePort 30900 | RustFS S3 |
| NodePort 30500 | Zot registry |
| NodePort 31080 | your apps (Kourier) — needs a `Host` header, so `curl` it from the terminal |

Inside the codespace's own terminal the hostnames work normally (`curl` and the labs'
`verify.sh` scripts resolve them from the container's `/etc/hosts`) — it is only the
browser, which is somewhere else entirely, that needs the Ports tab.

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
