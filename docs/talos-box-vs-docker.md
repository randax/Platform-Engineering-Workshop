# Can talos-box replace `talosctl cluster create docker`?

**Question asked:** would [randax/talos-box](https://github.com/randax/talos-box) (`tbx`) —
Talos as real VMs — replace Talos-in-Docker in this workshop and give attendees a "more
real" platform?

**Researched:** 2026-08-24, against talos-box `main` @ `053aecb` (2026-08-23), release
`v0.1.1` (2026-08-21), and this repo at `7eee665`. Primary sources only: the talos-box
source and docs, its GitHub issues/releases, Sidero's docs, and live registry/Factory
HEAD requests. Every claim below is marked **VERIFIED** (read in a primary source, cited)
or **UNVERIFIED** (inference, or an untested assumption).

**Short answer:** not for JavaZone 2026 — the delivery is Sept 1–3
(`README.md:15`, `PLAN.md:4-5`), eight days out, and a substrate swap invalidates the
prework, the offline story, the lifeboat, CI, and three of four rehearsals. But the
"don't" is about *timing and platform reach*, not about quality: talos-box is a
substantially engineered tool that solves several problems this workshop currently works
around, and it is a credible substrate for a **future edition** or an **opt-in pro
path**. Detail and a work list below.

Disclosure, because it affects how this document should be read: both repositories are
authored by the same person. talos-box's own wayfinder map already records the standing
scoping decision — "Migrating the workshop onto talos-box (prior scoping decision
stands)" is listed under *Out of scope*
([talos-box#211](https://github.com/randax/talos-box/issues/211), body). This document is
an independent re-examination of that decision, not an endorsement of either side.

---

## 1. What talos-box actually is

### Maturity — VERIFIED

| Fact | Evidence |
|---|---|
| Language: Go 1.26 | `go.mod:3` |
| Size: 437 `.go` files, ~99.8k LOC, 230 `_test.go` files | `find`/`wc` over the clone |
| Age: first commit **2026-07-20**, HEAD 2026-08-23 — about **five weeks old** | `git log --reverse` |
| 92 commits total (36 in July, 56 in August) | `git log --format=%ad` |
| Releases: `v0.1.0` (2026-08-21), `v0.1.1` (2026-08-21), 6 RCs | `gh release list` |
| Self-described status: "**pre-v1 scaffold**. The macOS build-from-source path is the currently validated path." | `README.md:8-10` |
| 15 open issues, including two open v1 verification gates (G1 macOS floor, G4 mirror through corporate security agents) and Linux packaging (#95/#101) | `gh issue list`, `docs/SPEC.md:589-621` |
| "Milestone: end-to-end workshop validation" (#27) is **still open** | `gh issue view 27` |

Unit-test density is genuinely high (230 test files) and there is a real KVM e2e lane
(below). This is not a weekend script. It is also five weeks old with an open v1 gate
list.

### Hypervisor per platform — VERIFIED

- **macOS:** Apple **Virtualization.framework** directly via `Code-Hex/vz` v3
  (`go.mod:6`, `docs/SPEC.md:65-66`). Apple Silicon only; **Intel Macs are unsupported**
  and by current design: "talosbox does not emulate; the guest architecture must match the
  host" (`docs/macos.md:25`); the vz backend is built `darwin && arm64` only
  (`internal/hypervisor/backend_vz_darwin.go:1`). An amd64 backend is a project decision,
  not a technical impossibility — but nobody has announced one. macOS 14+ floor (`docs/macos.md:23-24`).
- **Linux:** **QEMU/KVM directly over QMP, no libvirt** (`docs/SPEC.md:68-69`). Requires
  readable+writable `/dev/kvm`, QEMU 6.2+, OVMF/AAVMF, matching host/guest arch, "TCG
  emulation is never a fallback" (`docs/SPEC.md:44-46`).
- **Windows/WSL2:** **NOT supported today.** The premise in the question is wrong on this
  point. `docs/SPEC.md:26` lists "Windows/WSL2 hosts" as *out of scope*; WSL2 support is
  an open planning map ([#456](https://github.com/randax/talos-box/issues/456)) whose
  destination is "a handed-off implementation spec … implementation is a later build
  effort". A prototype did boot a cluster inside WSL2
  ([#461](https://github.com/randax/talos-box/issues/461)) and found real blockers,
  including that "the cluster does NOT survive closing all terminals (QEMU dies with the
  session scope)". Two bug tickets from that prototype are open (#467, #468).
- Lima and tart are explicitly not used (`docs/SPEC.md:71`).

### Networking model — VERIFIED, and this is talos-box's strongest card

One `/24` per cluster (`172.30.<n>.0/24`), host-routable node IPs, and a documented
**reachability contract**: "host ↔ node IPs; host ↔ LB VIPs (L2 or BGP); cluster ↔
cluster" (`docs/SPEC.md:260-264`). Address layout: `.1` host gateway, `.2–.179` nodes,
`.200–.239` Cilium LB-IPAM pool with `.200` the ingress VIP by convention
(`docs/SPEC.md:189-194`). macOS uses a per-cluster vmnet shared-mode network with a
helper routing `172.30.0.0/16` between attachments; Linux uses one `br-tbx<n>` bridge per
cluster with helper-managed nftables (`docs/SPEC.md:164-184`).

Plus embedded authoritative DNS: `*.<cluster>.k8s.test` → the ingress VIP, `<node>.<domain>`
→ node IP, wired on macOS through `/etc/resolver/` and on Linux through systemd-resolved
(`docs/SPEC.md:202-225`).

**What that means for us concretely:** on the *curated* path, `LoadBalancer` Services get
VIPs and browser URLs like `http://whoami.demo.k8s.test` resolve and answer. On the
substrate-only path (the one we would use) nothing announces VIPs until we add
`l2announcements.enabled` plus the LB-IPAM pool and L2 policy ourselves
(`internal/manifests/manifests.go:61-89`, `:106-157`); and the wildcard DNS returns `.200`
whether or not anything owns it (`internal/dns/resolver.go:15-41`). That is exactly the thing this workshop
cannot do today and papers over with nine hard-coded NodePorts (§2).

Caveats, all VERIFIED in talos-box's own words:
- L2 VIP failover on macOS takes ~40–50 s because macOS ignores GARP through vmnet;
  BGP mode is the fast-failover path there (`docs/macos.md:133-136`, SPEC §12 G2).
- `172.30.0.0/16` sits inside RFC1918 space corporations route over VPN wholesale;
  a full-tunnel VPN or a "no local LAN" policy blackholes every host→cluster path while
  `tbx doctor` still passes (`docs/corporate-lockdown-analysis.md:54-76`).

### Disk / persistence / Talos version — VERIFIED

- **Raw disk images, never in-VM installs** (`docs/SPEC.md:93`). Image Factory
  `metal-{arm64,amd64}.raw.xz` downloaded once per schematic+version+arch and
  decompressed; macOS clones each node disk with APFS `clonefile`, Linux copies
  (`docs/SPEC.md:104-107`).
- Node disks: `~/.talosbox/clusters/<name>/<node>.img`, **20 GB sparse** default
  (`docs/SPEC.md:128`). 25 GB free space required (`docs/macos.md:31`).
- Talos pin: default **v1.13.6** (`internal/talosversion/talosversion.go:13`), floor
  **v1.12.0** (`:17`), overridable per file/cluster via `talos.version`
  (`docs/SPEC.md:129-135`). Our pin, v1.13.8, is inside that window — but only the pinned
  default is CI-verified on every change (same lines).
- Cold-boot / apply timings, macOS, from the SPEC: `apply-config` lands in **~10 s** with
  no reboot; a configured node cold-boots in **~16 s**; a snapshot restore costs a
  ~1-minute cold boot (`docs/SPEC.md:107-110`, `:299-304`). The equivalent **Linux
  end-to-end timing gate is still open** (#97, `docs/SPEC.md:110`).

### kubeconfig / talosconfig — VERIFIED

Derived files at `~/.talosbox/clusters/<name>/{talosconfig,kubeconfig}`, re-minted by
`tbx up` from the cluster's `secrets.yaml`, and deliberately **never merged into
`~/.kube/config` or `~/.talos/config`** (`docs/walkthrough-cilium-ingress.md:36-45`).
Attendees `export KUBECONFIG=...`. On the substrate-only path there is no generated
config at all: nodes boot unconfigured into maintenance mode and the attendee runs
`talosctl gen config` / `apply-config` / `bootstrap` themselves (`docs/SPEC.md:16-21`,
`README.md:70-83`).

### Resources — VERIFIED

| | talos-box | this workshop today |
|---|---|---|
| Default topology | 1 CP + 2 workers, **2 GiB / 2 vCPU / 20 GiB disk each** (`docs/SPEC.md:320-322`, `internal/cluster/cluster.go:11-13`) | 1 CP + 1 worker |
| Memory | fixed guest capacity per VM (6 GiB for the default three); not host-preallocated — both backends attach a virtio balloon (`internal/hypervisor/qemu_config.go:299-307`, `backend_vz_darwin.go:282-286`) | **hard** cgroup ceilings: CP 4096 MB, worker 6144 MB — exceeding them OOMs (`scripts/versions.env:39-41`, `:55-57`) |
| CPU | 2 vCPU/node, fixed | **uncapped on purpose** — whole host to both containers (`scripts/create-cluster.sh:168-176`) |
| Host floor | **16 GB RAM**, all platforms (`docs/SPEC.md:33`) | 16 GB min / ≥10 GB to Docker, 4 cores, 40 GB disk (`scripts/versions.env:128-138`) |
| Pressure management | virtio ballooning + overcommit guard, **macOS only**; Linux sampler not implemented (`docs/SPEC.md:323-332`) | none needed — cgroup limits are soft |

**UNVERIFIED but load-bearing:** our stack idles at ~7.5–8 GB *inside* the cluster
(`docs/RESEARCH.md:141-149`), and the CPU uncapping in `HAZARDS.md:61-178` exists because
a 4-CPU cluster wedged at module 10. Under VMs the ceilings are just as hard as today's cgroup limits (correction: Docker's
limits were never "soft"), but they become *scheduler-visible* — kubelet sees the VM's
real capacity instead of the host's `/proc` — and you cannot hand a VM "the whole host"
the way `create-cluster.sh` hands both containers all NCPU. Sizing for the full
stack under VMs (probably 1 CP × 4 GiB + 1 worker × 8 GiB, 4+ vCPU each) has **never been
tested** and is risk #1 for any migration.

---

## 2. What in this workshop is coupled to Docker mode

All VERIFIED, citations from the coupling sweep.

**a. The create invocation.** `scripts/create-cluster.sh:179-190` — `talosctl cluster
create docker` with `--image ghcr.io/siderolabs/talos:v1.13.8`, `--memory-*`, computed
`--cpus-*`, `--subnet 10.5.0.0/24`, and `--exposed-ports` publishing nine NodePorts on the
controlplane container. Patches: `cni: none` + `proxy.disabled: true` + node labels +
the `/var/local-path-provisioner` kubelet bind mount (`:78-99`), plus a registry-mirror
patch for eight registries when the mirror container is up (`:113-151`).

**b. The kubeconfig rewrite — the deepest Docker coupling.** `create-cluster.sh:211-222`
reads the published port off the container (`docker port`) and rewrites the server to
`https://127.0.0.1:<port>`, because on macOS/Windows the host cannot route into the Talos
docker network (`:201-210`). *Under talos-box this whole workaround disappears* — node
IPs are host-routable by design. It is the one place where the migration deletes code.

**c. Service reachability.** Nine hard-coded NodePorts (`versions.env:104-115`) published
per container, mirrored in `.devcontainer/devcontainer.json:41-52`, pre-flighted in
`install.sh:104-120`, patched onto Gitea/ArgoCD at bootstrap
(`bootstrap-gitops.sh:81-82`, `:186-194`), baked into pins (`GITEA_HOST_URL`,
`ARGOCD_HOST_URL`) and into lab text and `verify.sh` files (`lab/common.sh:30`,
`lab/02-gitops/verify.sh:48-64`). The reason is stated in-tree: "NodePort instead of
LoadBalancer (**no LB implementation in the Talos-in-Docker cluster**)"
(`gitops/components/knative-serving/kourier.yaml:664-666`). Knative URLs use
`127.0.0.1.sslip.io` for the same reason (`serving-core.yaml:7799-7805`).

**d. Offline / pre-pull.** `cloudbox-init.sh` runs a **local OCI registry container**
(`registry:3.1.1` on `localhost:5001`, persistent Docker volume, `:161-166`) and
`crane copy`s 66 refs (~7.5 GB) into it (`:221-249`, `images.txt:14`), preserving index
digests deliberately (`:196-209`). Talos nodes reach it via
`host.docker.internal` (macOS/WSL2) or `10.5.0.1` (Linux) (`lib.sh:151-161`), with
`skipFallback: false`. Only three refs are `docker pull`ed to the host (`images.txt:26-32`).
`install.sh:196-330` verifies the mirror from *inside a container* and compares per-tag
architecture against the Docker daemon's.

  Under talos-box the equivalent exists and is arguably better: `tbx cache warm <list>`
  takes a pinned list of fully-qualified refs (`docs/SPEC.md:118-127`) — **but not our
  `images.txt` as-is**: its `[host]`/`[mirror]` section headers fail ref validation
  (`cmd/tbx/cache_warm.go:259-272`), so a generated mirror-only list is needed. The
  substrate-only image derivation also contains no Cilium/app images
  (`internal/provision/images.go:101-132`) — our 63 mirror refs must be warmed separately,
  and the Ollama model (`cloudbox-init.sh:260-274`) is outside talos-box's cache entirely. `tbx cache warm --check
  --deep` is the documented pre-travel gate, `tbx mirror offline on` makes cache misses
  fail hard instead of silently reaching upstream, and the machine config uses
  `skipFallback: **true**` so a node cannot bypass the mirror (`docs/SPEC.md:243-258`).
  There is a whole QA runbook for the venue case (`docs/qa/scenario-offline-venue.md`).
  **But**: it is a different store (`~/.talosbox/cache`), so the 11–14 minute prework
  (`docs/REHEARSALS.md:33-39`) must be redone and re-timed, plus a first-time Talos disk
  image download — **VERIFIED by live HEAD request, 2026-08-24**:
  `metal-arm64.raw.xz` = **99,457,344 bytes (~95 MB)**, `metal-amd64.raw.xz` =
  **214,022,292 bytes (~204 MB)** for v1.13.8 on the vanilla schematic. Against today's
  ~7.5 GB mirror that is noise; it is one more thing that must be present offline.

**e. CI.** `bootstrap-test.yaml` really creates the cluster on `ubuntu-latest`
(`:34-35`, `:116-117`, 90-min timeout, weekly cron). GitHub-hosted runners **cannot** run
this under talos-box on macOS: talos-box's own CI says so — "E2E tests require
Virtualization.framework, which is unavailable on GitHub-hosted runners"
(`talos-box/.github/workflows/ci.yml:28`). Its KVM e2e lives on **Depot** sandboxes with
a `test -w /dev/kvm` gate and hand-added iptables FORWARD rules
(`.depot/workflows/e2e.yml:12-46`). So a VM-mode workshop keeps CI only by moving the
bootstrap job to Depot or a self-hosted runner. Nested-virt on hosted Windows runners was
researched and rejected upstream
([talos-box#459](https://github.com/randax/talos-box/issues/459)).

**f. The Codespaces lifeboat dies.** `.devcontainer/devcontainer.json:12` uses
docker-in-docker precisely because "Talos-in-Docker needs a real Docker daemon inside the
container". A VM substrate needs `/dev/kvm` inside the Codespace. **UNVERIFIED** whether
any Codespaces machine type exposes KVM — I did not test it, and I am not aware of one.
Treat the lifeboat as lost under option (a) until proven otherwise. That matters:
the lifeboat is decision 1 in `PLAN.md:160-162`.

**g. Everything keyed on container identity.** `docker ps --filter
label=talos.cluster.name=cloudbox` is the cluster's identity in `create-cluster.sh:34`,
`destroy-cluster.sh:41`, `install.sh:106`, **`lab/01-cluster/verify.sh:12`** and
`solve.sh:14`. Module 01's teaching content is explicitly about containers, including
"Break a node on purpose: `docker pause cloudbox-worker-1`"
(`lab/01-cluster/README.md:110`). `catch-up.sh` and `check-consistency.sh` are substrate-agnostic (they operate on
Git/kubectl), so those survive. **The context guard is not**: `scripts/context-guard.sh:149-164`
whitelists only loopback and `10.5.0.2:6443`, so a `172.30.x.x:6443` endpoint is rejected
by every lab that sources `lab/common.sh`; the
`00`/`01` gates and `install.sh`'s Docker resource introspection
(`docker info -f {{.NCPU}}/{{.MemTotal}}`) do not.

**h′. Host services and embedded URLs.** Kagent reaches Ollama via `host.docker.internal:11434`
(`gitops/components/kagent/kagent.yaml:1453-1459`); that name does not exist inside a VM.
Browser URLs are baked into deployed config, not just lab prose: Backstage base URL/CORS
(`gitops/components/backstage/backstage.yaml:123-136`), portal-generated RustFS/Grafana links
(`gitops/components/portal/portal.yaml:103-110`), the Kourier verifier
(`lab/06-serverless/verify.sh:72-82`). And **talos-box has no `--exposed-ports` equivalent**
(`cmd/tbx/main.go:324-343`): a NodePort is reachable at `node-ip:port`, never at
`localhost:port`, so "keep NodePorts so URLs don't move" needs a new host-forwarding layer.

**h. kind-fallback.** `scripts/kind-fallback.sh` holds a *shape* contract — same nine
NodePorts, `disableDefaultCNI`, `kubeProxyMode: none`, same vendored Cilium chart
(`:5-9`, `:41-65`, `:135-142`). It is still Docker-based, so under a VM substrate it
becomes the *only* Docker path left — which is fine (it is the fallback) but it means
Docker Desktop stays a prerequisite for the fallback anyway.

---

## 3. Platform coverage vs the attendees we actually get

This is the argument that decides it. VERIFIED on both sides.

| Attendee laptop | Today (Docker) | Under talos-box |
|---|---|---|
| Apple Silicon Mac | ✅ (`README.md:138-143`) | ✅ tier one, the validated path |
| **Intel Mac** | ✅ "Fully supported" (`README.md:138-143`) | ❌ **never** (`docs/macos.md:25`, `docs/SPEC.md:26`) |
| macOS 13 | ✅ | ❌ (`docs/macos.md:24`) |
| Linux amd64/arm64 with KVM | ✅ | ✅ tier one — but packages unpublished; source or tarball only (`README.md:56-60`, release assets are three `.tar.gz`, no `.deb`/`.rpm`) |
| **Windows + WSL2** | ⚠️ best effort (`README.md:138-143`) | ❌ out of scope today (`docs/SPEC.md:26`); prototype-stage (#456) |
| Windows without WSL2 | ⚠️ (Docker Desktop w/ Hyper-V) | ❌ — a native Windows backend is explicitly out of scope (#456, "Out of scope") |
| Corporate laptop, no admin rights | Docker Desktop still needs an admin install, but often already present | ❌ blocked: **`sudo tbx system install`** registers a root launchd daemon; talos-box's own analysis rates MDM/EDR blocking of that path "**high likelihood at strict orgs**" (`docs/corporate-lockdown-analysis.md:82-99`) |
| Corporate laptop, full-tunnel VPN | works (all traffic is loopback/NodePort) | ⚠️ `172.30.0.0/16` capture blackholes host→cluster with doctor still green (`docs/corporate-lockdown-analysis.md:54-76`) |

Mitigations that exist: `v0.1.1` binaries **are** Developer-ID signed and submitted for
notarization (`scripts/release/sign-darwin.sh:19-52`, `.goreleaser.yaml:27-48`) and a
Homebrew cask is published (`randax/homebrew-tap`, `Casks/tbx.rb`) — so `brew install
randax/tap/tbx` is real, and `docs/macos.md:12` ("Planned; not published yet") is stale.
The cask still strips quarantine in a postflight because notary tickets lag
(`.goreleaser.yaml:117-120`). And talos-box's own calibration data point is encouraging:
the full path worked first try on a Mac running GlobalProtect 6.2.8 plus four other
tunnel products (`docs/corporate-lockdown-analysis.md:268-275`).

**Author's input (2026-08-24): no attendees use Intel Macs.** That retires the one
*permanent* row in this table. What remains is Windows/WSL2 — supported best-effort today,
unsupported under option (a) until talos-box's WSL2 map (#456) ships — plus the
corporate-laptop rows. Windows is the platform blocker for 2026; it is a temporary one.

---

## 4. What "more real" actually buys, and what our modules exercise

Sidero's own Docker-mode limitation list (VERIFIED, docs.siderolabs.com Talos v1.13,
*Local Platforms → Docker*): "Certain APIs are not available. For example `upgrade`,
`reset`, and similar APIs don't apply in container mode." and "When running on a Mac in
docker, due to networking limitations, VIPs are not supported."

| "More real" gain | Real? | Does a module exercise it? |
|---|---|---|
| Real kernel + EFI boot from a real disk image | yes (`docs/SPEC.md:82-110`) | No lab touches boot, kernel, or install disk |
| `talosctl upgrade` / `reset` / reboot | yes — unavailable in Docker per Sidero | **No.** No lab runs `talosctl upgrade`; module 10 "day-2 ops" is a **GitOps rollback**, not node ops (`lab/10-day2-ops/README.md:1-9`) |
| Real disks → real CSI (Longhorn/local-path with replicas) | yes (`docs/SPEC.md:417-451`) | Partly: we use local-path today via a kubelet bind mount (`create-cluster.sh:88-99`). Replica/HA storage is not taught |
| **LoadBalancer VIPs + Cilium L2 announcements / BGP** | yes (`docs/SPEC.md:189-241`) | **This is the real gain.** It would delete nine NodePorts, the sslip.io trick, and the `docker port` kubeconfig rewrite, and let attendees see `EXTERNAL-IP` actually populate |
| Host-routable node IPs / no 127.0.0.1 fiction | yes | Would fix `HAZARDS.md:227-234` (CI proves Linux-only routing) |
| Honest node failure (`tbx node stop` vs `docker pause`) | yes | Module 01 uses `docker pause` (`lab/01-cluster/README.md:110`) — would be rewritten, not gained |
| Real machine config authoring | already ours today; the substrate-only tbx path preserves it exactly (`docs/SPEC.md:16-21`) | Module 01 reads machine config via talosctl (`lab/01-cluster/README.md:59-63`) |
| Snapshots (`tbx snapshot create/restore`) | yes (`docs/SPEC.md:299-304`) | Nothing today. **Would be a genuinely new capability**: an instructor-grade "restore to a known-good end state" that `catch-up.sh` currently does via Git force-push only |
| Multi-cluster / inter-cluster routing | yes (`docs/SPEC.md:260-264`) | Not in scope for 240 minutes |

**Honest verdict on "more real":** of the eight items, exactly **two** would change what
attendees see in the current 240-minute module list — LoadBalancer/DNS reachability, and
(as an instructor tool) snapshots. The rest are realism the curriculum does not currently
cash in. "More real" is true, and mostly unexercised.

There is also a "less real" that matters: under Docker, `kubelet` in a Talos node reads
the *host's* `/proc`, so the scheduler believes it has the whole VM
(`docs/HAZARDS.md:135-146`). Under VMs, resource limits become true — which is more
honest and *harder*, because the stack must then actually fit in the memory you assign.

---

## 5. Time, size and risk against the 240-minute budget

VERIFIED numbers, both sides:

| | Today | talos-box |
|---|---|---|
| Prework (mirror) | `cloudbox-init.sh` **11:03–13:39**, 7.25–7.87 GB, 66 refs (`docs/REHEARSALS.md:33-39`) | `tbx cache warm` + `tbx cache pull`; unmeasured for our 66 refs. Plus 95 MB (arm64) / 204 MB (amd64) Talos raw image, live-measured |
| Cluster create at the venue | **2:09 best / 2:24 worst**, cold mirror (`docs/REHEARSALS.md:46-60`) | Smoke bar: create returns "in < 5 min" cold, nodes in `maintenance` within 3 min (`docs/qa/smoke-macos.md:51-55`); Linux "raw-image disk copy is slower than macOS clonefile" (`docs/qa/smoke-linux.md:7`). Curated CNI budget is **10 min**, storage **25 min** (`internal/daemon/provision.go:22-26`) |
| Total script time, all 11 modules | **16–32 min** of 240 (`docs/REHEARSALS.md:12`) | Unknown |
| Rehearsals | 4, all on Apple Silicon + Colima 8 CPU/16 GiB (`docs/HAZARDS.md:8-9`) | 0 for this workshop |

The budget is not obviously blown — a 5-minute create against a 35-minute module-01
budget is survivable. The risk is not the mean; it is the variance on 30 unknown laptops
with 0 rehearsals, versus a path with 4.

---

## 6. Options and recommendation

### (a) Replace Docker mode outright — **No, not for 2026**

Blockers, in order: Intel Macs and Windows attendees lose support entirely (§3); the
Codespaces lifeboat needs `/dev/kvm` (§2f, unverified but likely fatal); CI must leave
GitHub-hosted runners (§2e); prework, offline gate, all nine NodePort URLs, module 01, and
the 00/01 verify gates all change (§2); and four rehearsals' worth of timing evidence is
invalidated eight days before delivery. Also: talos-box's own end-to-end workshop
validation milestone (#27) is open, and G4 — "confirm host-bound mirror traffic passes on
a GlobalProtect-managed machine" — is an open gate (`docs/SPEC.md:601-602`) that is
*exactly* the venue-laptop question.

### (b) Optional "pro path" with the same `verify.sh` contract — **Yes, but after JavaZone**

This is the interesting option and it is more feasible than it looks, because the
`verify.sh` contract is substrate-agnostic: the labs assert against `kubectl`, Git and
HTTP, not against Docker — with three exceptions (`lab/00-setup/verify.sh` Docker
resource checks, `lab/01-cluster/verify.sh:12` container labels, and the NodePort URLs in
`lab/common.sh:30`). A `create-cluster-tbx.sh` producing the same *shape* (1 CP + 1
worker, `cni: none`, Cilium 1.20.0 from our vendored chart via the substrate-only path,
NodePorts still published so URLs don't move) is the minimum-diff version, and the
substrate-only path is explicitly designed for exactly this: "To keep bootstrapping and
CNI installation entirely attendee-managed, omit `cni`"
(`docs/walkthrough-cilium-ingress.md:131-133`). Note the curated path pins Cilium
**1.19.6** (`internal/provision/cilium.go:39`) against our 1.20.0 — another reason to use
the substrate-only path, not `--cni cilium`.

### (c) Demo / stretch module only — **Yes, cheapest real value, and viable sooner**

An instructor-run demo (or an optional module 11) showing a real `LoadBalancer` getting a
VIP, `http://whoami.demo.k8s.test` in a browser, `tbx snapshot restore`, and a
`talosctl upgrade` — the three things Docker mode structurally cannot show. Costs no
attendee prerequisite, no CI, no lifeboat change, and no rehearsal invalidation, because
it runs on the instructor's Apple Silicon Mac only. This is the honest way to *say* "here
is what the real thing looks like" without making 30 laptops prove it.

### (d) Don't — for the 2026 delivery, yes; as a permanent answer, no

The tool is good enough that a flat "no" would be wrong. It is the timing and the
platform matrix that say no, and all of which change over time (WSL2 map #456,
notarized releases, Linux packaging #95/#101). Intel Macs are not a factor for this
audience.

### Recommendation

**For JavaZone 2026 (Sept 1–3): (d) + (c).** Keep `talosctl cluster create docker` as
the attendee substrate; do not touch the substrate eight days out. If there is appetite
and instructor time, prepare a 5-minute talos-box *demo* for the module-01 or module-10
slot — it directly answers the honest question attendees will ask ("is this a real
cluster?") and costs the attendees nothing.

**For the next edition: (b), gated on evidence.** Build `create-cluster-tbx.sh` as an
opt-in path holding the same shape contract kind-fallback holds, run the full module set
against it, and promote it to default only if — and only if — WSL2 has shipped in talos-box and
been rehearsed. With Intel Macs out of the picture, Docker mode need only survive as the
compatibility path until then (and for Codespaces / locked-down laptops), not forever.

---

## 7. Concrete work list and the unknowns each item retires

Ordered; each line names the risk it retires. None of this should start before Sept 3.

**Must test before any of (a)/(b) is credible — these are the unknowns, not the work:**

0. **URL strategy decision.** Either real `LoadBalancer` + `*.k8s.test` everywhere, or a
   localhost-forwarding layer that fakes today's nine ports. There is no free
   "keep NodePorts" option (§2h′). Also: context-guard support for `172.30.x.x`, and an
   Ollama reachability answer (the VM gateway `.1` instead of `host.docker.internal`).

1. **Does the full stack fit in VMs?** Size 1 CP + 1 worker under `tbx`, run modules
   01–09 to the ~73-pod end state, record RSS on a 16 GB host. *Retires:* the memory/CPU
   wall (§1, `docs/RESEARCH.md:141-149`, `docs/HAZARDS.md:61-178`). **Biggest unknown.**
2. **Offline, end to end.** `tbx manifests <c> images | tbx cache warm -` plus our 66
   refs, then `tbx mirror offline on` + network cut + full create. Time the prework.
   *Retires:* the offline-first requirement. A ready-made runbook exists:
   `talos-box/docs/qa/scenario-offline-venue.md`.
3. **Can Codespaces give `/dev/kvm`?** *Retires:* the lifeboat question (§2f). If no,
   the lifeboat permanently stays Docker-mode — which is an acceptable answer, but it
   must be a decided one.
4. **Corporate-laptop dry run** on an MDM-managed machine: `sudo tbx system install`
   under Jamf/Intune, plus a full-tunnel VPN with `172.30.0.0/16`. *Retires:* talos-box
   gate G4 and risk #2/#3 of its own lockdown analysis — and tells us how many attendees
   would be locked out.
5. **CI substrate.** Prove the bootstrap job on Depot KVM (talos-box's `.depot/workflows/e2e.yml`
   is a working template) or accept losing the weekly green. *Retires:* §2e.

**Then, if those pass:**

6. `scripts/create-cluster-tbx.sh` — substrate-only `tbx up`, our `talosctl gen config`
   with our `cni: none` + kubelet-mount patch, our vendored Cilium 1.20.0, NodePorts kept
   so no URL moves. Keep `talosctl cluster create docker` untouched.
7. Substrate-neutralize the three coupled gates: `lab/00-setup/verify.sh` (Docker
   resource introspection), `lab/01-cluster/verify.sh:12` (container labels), and the
   `install.sh` Docker preflight — each behind a substrate switch, per Principle 3's
   exit-0 contract.
8. Only then consider moving URLs from NodePort to `LoadBalancer` + `*.k8s.test`. This
   is the payoff, and it touches `lab/common.sh`, `versions.env:104-115`, seven component
   manifests, `bootstrap-gitops.sh`, and the devcontainer. Do it as its own change, with
   its own rehearsal.
9. Re-run all four rehearsal scenarios. Nothing about timing (`docs/REHEARSALS.md`)
   transfers.

**Known upstream blockers to watch** (all VERIFIED open): talos-box #27 (end-to-end
workshop validation), #456/#462/#463/#464 (WSL2), #95/#101 (Linux packages), #467/#468
(packaged Linux helper units broken, Linux doctor bugs), SPEC gates G1 (macOS 14/15 boot
floor) and G4 (mirror through corporate security agents), G9 (Linux full-cluster CI).

---

## Appendix: what I could not verify

- Whether GitHub Codespaces exposes `/dev/kvm` on any machine type (§2f).
- Any timing for our stack under talos-box — no measurement exists on either side.
- Whether 2 GiB × 3 (talos-box default) or any specific VM sizing holds our ~73-pod end
  state. Not tested by anyone.
- talos-box behaviour on an MDM/EDR-locked Mac beyond its own single-machine calibration
  run (`docs/corporate-lockdown-analysis.md:268-275`); G4 remains open by its authors' own
  account.
- Whether the Talos dashboard TUI renders interactively over `hvc0` (`docs/qa/MATRIX.md:33`) —
  matters only because `lab/01-cluster/README.md:61` tells attendees to run
  `talosctl dashboard`.
- Linux end-to-end cold-boot timing (talos-box #97, `docs/SPEC.md:110`).

---

## Verification pass (gpt-5.6-sol, high reasoning, 2026-08-24)

An independent skeptical review against the same clone confirmed the platform matrix,
networking model, maturity numbers, version pins and the recommendation, and **refuted
four claims** in the first draft, which have been corrected above:

1. Docker memory limits are hard cgroup ceilings, not soft (§1 Resources).
2. `scripts/context-guard.sh` is *not* substrate-agnostic (§2g).
3. "Keep NodePorts so URLs don't move" is not available — talos-box has no
   `--exposed-ports`; a forwarding layer or a URL migration is mandatory (§2h′, §7 item 0).
4. `scripts/images.txt` cannot be fed to `tbx cache warm` unchanged (§2d).

Also noted: talos-box ships seven RC tags, not six; its README/SPEC still call Linux KVM
CI "pending" although `.depot/workflows/e2e.yml` exists; the WSL2 work lives on
`origin/prototype/wsl2-smoke` as a self-labelled throwaway script whose checked-in run
never bootstrapped Kubernetes — "final testing" may be true outside the tree, but it is
not substantiated by it. The reviewer's closing line: do not treat
`create-cluster-tbx.sh` as a small or shape-preserving change.
