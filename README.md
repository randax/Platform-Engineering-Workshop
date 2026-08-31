# Cloud on Your Terms: Building Your Own Cloud-Native Platform

What happens when you can no longer trust your cloud provider's pricing, jurisdiction,
or roadmap? In this workshop you build the answer: a complete cloud-native platform
(Kubernetes, GitOps, databases-as-a-service, object storage, self-service
infrastructure) running entirely on hardware you own. Your laptop becomes the cloud.
Everything is open source, everything is pinned, and everything keeps working after you
leave the room. That running platform, and the mental model of how it fits together, is
the one thing a video or an AI assistant can't give you.

## Workshop facts

| | |
|---|---|
| **Conference** | JavaZone 2026, Sept 2–3, NOVA Spektrum, Lillestrøm |
| **Workshop day** | The day before the main conference (see the JavaZone program for exact day and venue) |
| **Duration** | 240 minutes (4 hours), hands-on |
| **Speakers** | Hans Kristian Flaatten, Øyvind Randa |
| **Repo** | Everything is public: labs, solutions, scripts. Finish at home if you want. |

## What we're building

A two-node Talos Linux Kubernetes cluster on your laptop, with an in-cluster git server
and a GitOps engine delivering the entire platform on top: real VMs via
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

The all-day mechanic: capabilities are a catalog of ArgoCD `Application` manifests. Copy
one from `gitops/catalog/` into `gitops/apps/`, commit, push to *your own* in-cluster
Gitea, watch ArgoCD converge. Edit → push → converge. That's GitOps, and it never
touches GitHub or the conference WiFi.

On object storage: we use [RustFS](https://rustfs.com), an Apache-2.0 alternative to
MinIO, whose open-source community edition was discontinued in 2025–26 in favor of the
proprietary AIStor. Same S3 API, licence you can live with.

Every component is a deliberate choice against a rejected alternative: Talos over
kubeadm, Cilium over kube-proxy, in-cluster Gitea over GitHub, Crossplane v2 over Helm,
the Victoria stack over kube-prometheus-stack. Tradeoffs in **[docs/STACK.md](docs/STACK.md)**.

## The Cloudbox Console

The platform's front door: a bespoke **Go + htmx** portal (source in `apps/`),
server-rendered, fully **offline** (no CDN, one vendored `.js` file, no build step). A
read-only ServiceAccount token lets it read the Kubernetes API and surface everything
you built (ArgoCD apps, CNPG databases, Knative services), plus **per-component metrics,
logs, and traces** from the on-cluster OTel stack (VictoriaMetrics / VictoriaLogs /
VictoriaTraces via the OTel Collector). Light and dark themes, responsive down to a
phone. Small enough to read over coffee: [`apps/portal/`](apps/portal/).

<p align="center">
  <img src="docs/screenshots/console-component-monitoring-dark.png" alt="Cloudbox Console, a component's Monitoring page: CPU/memory sparklines and a live log tail" width="49%" />
  <img src="docs/screenshots/console-components-dark.png" alt="Cloudbox Console, the Components health page, per-namespace status" width="49%" />
</p>

<p align="center"><em>Left: a component's Monitoring detail (CPU/memory sparklines, live log tail from the OTel stack). Right: the Components health page. Both dark mode; the console ships light + dark.</em></p>

You build it in [module 08](lab/08-portal); it comes fully alive in the
[capstone](lab/09-capstone). All screenshots (desktop, mobile nav, the "enable
observability" gated state, database metrics): [docs/screenshots/](docs/screenshots/README.md).

## Start here: do this BEFORE the conference

Conference WiFi carries keystrokes, not gigabytes; setup downloads roughly 7.5 GB of
container images (7.7 GB on x86-64). **Run these three steps at home, on a network you
trust:**

```bash
git clone https://github.com/randax/Platform-Engineering-Workshop.git
# (will be renamed to jz-2026-platform-engineering — the old URL will redirect)
cd Platform-Engineering-Workshop

./scripts/dev-setup.sh        # 1. install the pinned CLI tools, via mise
mise run init                 # 2. pre-pull all pinned images (~7.5 GB, be patient)
mise run preflight            # 3. preflight: prints ✅/❌ for everything
```

Steps 2 and 3, like every command below, are mise tasks; the underlying scripts live in
`scripts/` if you prefer them, and `mise tasks` lists them all. Step 1 stays a script
because it is what installs mise in the first place.

**If step 3 is all green, you are done.** If not, the output names what to fix; if it
cannot be fixed, the [devcontainer lifeboat](#plan-b-devcontainer--codespaces) has you
covered. Bring your laptop and its power supply.

### Which substrate will I get?

The cluster runs on one of two substrates; the scripts detect which and record the
answer in `~/.cloudbox/substrate`, so every later script agrees. Every module after 01
is identical on both: same labs, same `verify.sh` scripts, same URLs.

| | **Docker** (Talos-in-Docker) | **tbx** (real Talos VMs) |
|---|---|---|
| Who gets it | everyone by default | Apple Silicon macOS, or Linux with KVM, **and** only if you install the helper below |
| Extra setup | none beyond Docker itself | one privileged install, once |
| Needs Docker | yes | **no**, not at all |
| Force it | `CLOUDBOX_SUBSTRATE=docker` | `CLOUDBOX_SUBSTRATE=tbx` |

`mise run preflight` prints which one you will get, and on a fallback to Docker it
prints the `tbx doctor` line that decided.

### Optional: real Talos VMs with tbx

Step 1 already installed the `tbx` **binary** (pinned in `mise.toml`). Only you can
install its privileged helper:

```bash
tbx system install && tbx doctor    # macOS: asks for your password itself
```

"exit 0, no FAIL" is the bar. Skip this entirely and nothing breaks: `tbx doctor` fails
and the scripts put you on Talos-in-Docker, which runs the same workshop. Two rules:
never run `sudo tbx …`, because sudo's PATH may find a different tbx than yours
(`tbx system install` elevates itself; if you truly must, `sudo "$(command -v tbx)"`);
and keep exactly one tbx/tbxd/tbx-helper triad on PATH, or `tbx doctor` warns. A Homebrew
`randax/tap/tbx` exists but is not pinned, so mise stays the supported route.

On **Linux with KVM**, mise ships the three binaries but there is no `system install`:
the helper is a systemd unit set that talos-box's `docs/linux.md` installs from a source
checkout. Check out the tag pinned as `TBX_VERSION` in `scripts/versions.env` so daemon
and helper match the pinned client.

> **Before you install the helper, read this.** On one rehearsal machine tbx caused a
> **macOS kernel panic** — a hard reset with no warning — three times, on three tbx
> versions. Upstream traced it to a bug in XNU's socket content filter, not tbx itself,
> needing three ingredients together: a **content-filter network extension** (Little
> Snitch, some VPN or endpoint-security products), **recent Apple silicon**, and a
> socket-busy process. Other machines run tbx all day without trouble, so it stays
> supported and the default where `tbx doctor` passes. If you run a content filter
> and would rather not gamble your laptop, skip the helper and use Docker. Details and
> current state in [`docs/HAZARDS.md`](docs/HAZARDS.md).

### The offline story, on both substrates

The offline guarantee is a registry mirror the nodes pull through: on the Docker path a
`cloudbox-mirror` container on port 5001, on the tbx path talos-box's own mirror
(`tbx cache warm` fills `~/.talosbox/cache` and tbxd serves it to the VMs at the cluster
gateway). On tbx, step 2 also warms the Talos disk image (`tbx cache pull`, 95 MB on
arm64, 204 MB on amd64); step 3 asserts a complete `disk.raw` is in `~/.talosbox/cache`
and grades the images with `tbx cache warm --check` (use `--check --deep` before you
travel). At the venue, `tbx mirror offline on` stops tbx's mirror fetching upstream, so
a missing image surfaces as a mirror miss rather than being quietly filled over the
WiFi; the nodes keep `skipFallback: false`, so the pull then goes direct, slowly and
visibly.

One trade-off: tbx's store serves VMs only, so on a tbx laptop the Talos-in-Docker
fallback is **not** offline-ready unless you also run
`CLOUDBOX_SUBSTRATE=docker mise run init` at home (needs Docker, ~7.5 GB more).

### Your `kubectl` gets a workshop-only kubeconfig

Step 1 offers to hook [mise](https://mise.jdx.dev/) into your shell. **Say yes.**
Besides putting the pinned tools on your PATH, it makes `KUBECONFIG` point at
**`~/.kube/cloudbox.conf`** while you are inside this repo: this workshop's cluster and
nothing else, so tearing it down leaves nothing for `kubectl` to silently fall through
to, and your own contexts are never modified. `echo $KUBECONFIG` shows which file you
are on. Decline and everything lands in `~/.kube/config` as it always did; the workshop
still works, and the scripts refuse to touch a non-workshop context either way. Just
don't do half of each: running scripts through `mise run` / `mise exec` while typing
bare `kubectl` in a shell that never got the pin puts your cluster and your terminal on
two different files. `./scripts/install.sh --check` tells you which side you are on.

### Hardware: honest numbers

| | tbx (real Talos VMs) | Docker (Talos-in-Docker) |
|---|---|---|
| Minimum | 16 GB RAM, 4 cores, 40 GB free | 16 GB RAM with **≥10 GB and ≥4 CPUs to Docker**, 40 GB free |
| Comfortable | 32 GB | 32 GB |
| What you get | real `LoadBalancer` VIPs, a real L2 segment | the same labs, the same URLs, via published ports |

The full platform idles at roughly 8 GB inside the cluster; 16 GB machines fit, but
close your Electron zoo. On Docker: OrbStack, or a Docker Desktop with a raised memory
limit; WSL2 users raise it in `.wslconfig`. On tbx the VM sizes are pins
(`TBX_CP_MEMORY` / `TBX_WORKER_MEMORY` in `scripts/versions.env`): a boot ceiling, not
a permanent reservation. talos-box balloons memory back out of a running node when the
host comes under pressure, which keeps the laptop alive and means a hungry browser can
shrink your cluster mid-module. Close the zoo anyway.

### Platform support matrix

| Platform | Substrate | Support |
|---|---|---|
| macOS, Apple Silicon | tbx (Docker if `tbx doctor` fails) | fully supported |
| Linux, amd64/arm64 with KVM | tbx (Docker if `tbx doctor` fails) | fully supported |
| macOS, Intel | Docker | fully supported |
| Windows via WSL2 | Docker | best-effort; pair up if it fights you |
| GitHub Codespaces / devcontainer | Docker | the lifeboat, tested weekly in CI |

On Linux, watch out for firewalld/nftables interference on either substrate.

**tbx on macOS can run its VMs on two hypervisors** (tbx ≥ v0.1.6). The default is
Apple's Virtualization.framework (`vz`) — zero install, leave it alone if it works. If
Virtualization.framework itself misbehaves on your machine, QEMU/HVF is the escape hatch:

```bash
brew install qemu     # macOS 15+ — on macOS 14 Homebrew builds QEMU without HVF
CLOUDBOX_TBX_HYPERVISOR=qemu mise run cluster:create
```

The choice is baked into the cluster at creation and is **immutable**: to move an
existing cluster to the other hypervisor, `mise run cluster:destroy` first, then
create with the override. Same labs, same URLs, same mirror on either backend. One
honest caveat: the macOS kernel-panic hazard in `docs/HAZARDS.md` is a content-filter
bug in macOS itself and is *not* avoided by switching to QEMU — for that, deactivate
the content-filter extension or use the Docker substrate.

The recorded substrate lasts as long as the cluster: `destroy-cluster.sh` removes the
file, and the next `create-cluster.sh` decides again from scratch, printing the
substrate it just forgot and the command that keeps it
(`CLOUDBOX_SUBSTRATE=<what it was> ./scripts/create-cluster.sh`), worth using if you
chose deliberately, because detection will not know you did.
`catch-up.sh <module> --rebuild` carries it across for you.

**The override picks; it does not overrule what is already there.** Once a cluster
exists, `~/.cloudbox/substrate` is a *record*, not a preference: `create-cluster.sh`,
`destroy-cluster.sh`, `kind-fallback.sh`, `--refresh-endpoint` and
`install.sh --write-hosts`/`--add-hosts` all refuse, before touching anything, when the
substrate you ask for is not the recorded one. On a machine with no record (a fresh
laptop, CI) the override is simply the answer. Changing substrates is two commands and
they say so:

```bash
CLOUDBOX_SUBSTRATE=tbx mise run cluster:destroy       # (or ./scripts/kind-fallback.sh --delete)
CLOUDBOX_SUBSTRATE=docker mise run cluster:create
```

**Half-installed tbx.** If `tbx` is on your PATH but its helper daemon is not running,
the docker path cannot ask it whether a `cloudbox` cluster exists there. It continues
anyway when this machine carries no trace of one (`~/.cloudbox/substrate`,
`~/.cloudbox/cloudbox.tbx.yaml` and `~/.talosbox/clusters/cloudbox` all absent); with a
trace present it stops rather than risk two
clusters of the same name: fix tbx, or set `CLOUDBOX_IGNORE_TBX=1` if you know those
VMs are down.

**One catalog extra is amd64-only:** Backstage's CNOE image has no arm64 build, and a
tbx VM emulates nothing, so on Apple Silicon that stretch item needs the Docker
substrate. `install.sh --check` warns. Nothing on the core path is affected.

## At the venue

You'll run these together with us; no need at home (you can, though: the whole workshop
works offline once the images are pre-pulled and the Helm charts are vendored, and they
are, in `scripts/manifests/`).

```bash
mise run cluster:create     # Talos cluster (tbx VMs or Docker) + Cilium
mise run gitops:bootstrap   # in-cluster Gitea + ArgoCD
mise run gitops:seed        # seed your cloud's git with the platform tree
```

**On the Docker substrate, `mise run cluster:create` asks for your password once, at the
very end.** It is the only sudo in the workshop: Docker has no resolver, so the workshop
hostnames come from a marked `# cloudbox-begin` block in `/etc/hosts`, written via
`sudo tee`; `./scripts/install.sh --print-hosts` shows exactly what goes in (WSL2: the
same lines also belong in `C:\Windows\System32\drivers\etc\hosts`, edited as
Administrator). Decline the password and every `*.cloudbox.k8s.test` URL fails on a
perfectly healthy cluster; the cluster stays up, and
`./scripts/install.sh --write-hosts` writes the block whenever you are ready. That is
also the fix when the names stop resolving: **WSL2 regenerates `/etc/hosts` on every
restart** unless you tell it not to (see `lab/00-setup`). *Every*
`mise run cluster:destroy` on the Docker substrate *asks* to remove the block, not
only `--purge-mirror`, which additionally forgets the extra names you added with
`--add-hosts`; decline that prompt and the teardown still finishes, saying which lines
remain. On tbx nothing touches `/etc/hosts`; talos-box's own resolver answers the names.

Fell behind or broke something interesting? `mise run catch-up <module>` force-pushes
the canonical state for that module to your Gitea and lets ArgoCD converge. Scripted
state, not hope.

If neither substrate will cooperate, `mise run cluster:fallback` gives you a
kind+Cilium cluster meeting the same contract: the same vendored Cilium with the **same
ingress values**, host port 80 mapped to the ingress, and the same marked `/etc/hosts`
block, so every `*.cloudbox.k8s.test` hostname works and **modules 02 onward are
identical**. You lose only the Talos content of module 01: `lab/01-cluster/verify.sh`
checks a Talos cluster, so on the lifeboat it prints "not gradeable here" and exits 0
rather than failing a cluster that is working as documented.

kind is not one of the two substrates, but it *is* a recorded identity: the script
writes `kind` into `~/.cloudbox/substrate`, which tells `install.sh --check` to grade
this machine with Docker semantics, fills the image mirror for the right architecture,
and makes `create-cluster.sh` and `destroy-cluster.sh` **refuse** rather than build a
second cluster over the lifeboat or delete its hostnames.

Tear the lifeboat down with `./scripts/kind-fallback.sh --delete`: it deletes the kind
cluster, removes the `/etc/hosts` block it wrote (one sudo prompt; decline and it names
the lines to delete by hand) and clears the identity. It removes the block only when the
identity says `kind`, so on a Docker-substrate machine it cannot take out a live
cluster's names; and it clears the identity only once the cluster is gone *and* the
block is removed or proven absent, so a declined sudo leaves you able to retry. If the
file is missing (a lifeboat taken before this existed), say so for the session:
`CLOUDBOX_SUBSTRATE=kind mise run preflight`. The same override works for the
teardown, `CLOUDBOX_SUBSTRATE=kind ./scripts/kind-fallback.sh --delete`, but there it is
honoured only against **kind-specific** proof: `kind get clusters` must list `cloudbox`,
or Docker must still hold containers labelled `io.x-k8s.kind.cluster=cloudbox`. The
`/etc/hosts` block is *not* proof: the docker substrate writes an identical one, and
accepting it would let an environment variable delete a live Talos cluster's hostnames.
Once proved, `kind` is written back into `~/.cloudbox/substrate` immediately, so a retry
after a declined sudo needs no override at all. The teardown exits non-zero whenever
anything is left; it needs Docker running (it asks the daemon for the containers) but
neither `kind` nor `kubectl` on `PATH`.

## Lab overview

Labs live in `lab/`. Each module states an **outcome** ("make your cluster reach state
X"), ships a `verify.sh` that checks it against the live cluster, and layers hints from
gentle nudge to full solution. You choose how much to open.

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

Core modules are the plan; stretch modules are for the fast 20% — and for your couch
afterwards. Canonical end-states live in `solutions/`.

## Using AI assistants

**Yes. Please.** Claude Code, Copilot, kubectl-ai, whatever you run: point it at your
cluster. The labs are outcomes, not command lists, because copying 12 commands (yourself
or via an LLM) teaches nothing; the goal is a running platform and the mental model, not
the typing. One warning shot: module 05 includes a fault
where the obvious AI diagnosis is plausible and wrong. Verifying what an agent tells you
against the live system is the 2026 skill, and we'll practice it.

**The house style: your assistant is a tutor, not a chauffeur.** This repo's
instructions (`CLAUDE.md` / `AGENTS.md`) ask coding agents to *coach* during the
workshop (explain, point at the next hint layer, debug your environment with you) and to
decline to simply do the labs for you. It's advisory: you can delete the file or talk
your agent past it, except that the only thing you'd take home from a workshop your
agent did is a warm laptop. One deliberate carve-out: **environment and tooling failures
are not the lesson.** Docker won't start, a mise shim misbehaves, a download died
halfway? Sic your agent on those with everything it has. Yak-shaving is nobody's
learning objective; the platform concepts are.

## Plan B: devcontainer / Codespaces

If `mise run preflight` won't go green on your machine, don't burn workshop time on it. This repo ships a [devcontainer](.devcontainer/devcontainer.json) with
Docker-in-Docker and all tools preinstalled, the exact same workshop content:

- **GitHub Codespaces**: Code → Create codespace on this repo. Pick a machine with
  **4 cores / 16 GB RAM** or larger, then run the same three prework steps inside it.
- **Locally**: any editor that speaks the [Dev Containers spec](https://containers.dev)
  (VS Code, JetBrains, `devcontainer` CLI), though if Docker works locally you likely
  don't need the lifeboat.

**One thing is different in Codespaces: how you open a service.** Everywhere else the
workshop's URLs are hostnames (`http://gitea.cloudbox.k8s.test`). In a codespace your
browser is not on the machine the cluster runs on; it reaches the container through
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
`verify.sh` scripts resolve them from the container's `/etc/hosts`); only the browser
needs the Ports tab.

Codespaces runs in Microsoft's cloud — a pragmatic irony for a sovereignty workshop, and
exactly why it's the lifeboat and not the boat.

## Workshop leaders

### Øyvind Randa

Software Architect at NextGentel and Lead Organizer for GDG Bergen

### Hans Kristian Flaatten

Platform maker, dream awaker | CNCF Ambassador | Google Developer Expert | Grafana
Champion | Co-host of Plattformpodden | Platform Engineer in Norwegian Government |
Open Source Maintainer

## Getting help

- **Before the workshop:** open an issue on this repo; broken prereqs are our bug, not yours.
- **During the workshop:** sticky notes signal silently (red = stuck); the two presenters cover the room, and recurring questions get answered to everyone.
- **After:** everything here is public and pinned. `git tag javazone-2026` is the state we shipped.

## License

Apache License 2.0, see [LICENSE](LICENSE). Take it, fork it, run your cloud on your terms.
