# talos-box as primary substrate, Docker as first-class fallback — design

**Date:** 2026-08-24 · **Target:** JavaZone 2026, Sept 1–3 · **Basis:** `docs/talos-box-vs-docker.md`
**Decision owner:** Øyvind Randa. The analysis recommended against doing this for 2026; the owner
chose to proceed with the risks stated there. This spec records how, and the gate that flips the
default back if the rehearsal fails.

## Goal

Attendees on Apple Silicon macOS (and Linux with KVM) run the workshop on real Talos VMs via
[talos-box](https://github.com/randax/talos-box) (`tbx`), with real `LoadBalancer` VIPs and
`*.cloudbox.k8s.test` URLs. Everyone else — Windows/WSL2, Codespaces, CI, machines where `tbx doctor`
fails — runs the identical labs on `talosctl cluster create docker`. **One lab text, one URL scheme,
one `verify.sh` contract, one image mirror.**

## Non-goals (2026)

- Adopting `tbx cache warm` / `tbx mirror` — the crane mirror on `localhost:5001` stays the single store.
- Using talos-box's curated Cilium (1.19.6). We install our vendored Cilium 1.20.0 on both substrates.
- Snapshots, `talosctl upgrade`, multi-cluster, BGP, TLS on ingress, Linux `.deb`/`.rpm` for tbx, WSL2 tbx.
- Changing the module list, timeline or verify/solve contract.

## 1. Substrate layer

```
scripts/create-cluster.sh            dispatcher: resolves CLOUDBOX_SUBSTRATE, sources backend, runs shared post-steps
scripts/substrate/docker.sh          today's create-cluster.sh body (moved, behaviour-identical) → provides create/destroy/introspect
scripts/substrate/tbx.sh             new backend
scripts/lib.sh                       substrate_detect(), substrate_host_gateway(), substrate_api_endpoint()
```

**Resolution.** `CLOUDBOX_SUBSTRATE` ∈ `{tbx, docker}`. Unset → `tbx` when `command -v tbx` and
`tbx doctor` exit 0 (and `uname -m` is arm64 on darwin), else `docker`. The chosen value is written to
`~/.cloudbox/substrate` on create so `destroy-cluster.sh`, `install.sh --check`, `lab/00`, `lab/01`,
`catch-up.sh` and `context-guard.sh` read the *same* answer later instead of re-detecting.
`install.sh --check` prints which substrate will be used and the failing `tbx doctor` line when falling back.

**Contract both backends must satisfy** (asserted by `lab/01-cluster/verify.sh`):
- kube context `admin@cloudbox`, 1 control plane + 1 worker, Talos `${TALOS_VERSION}` (v1.13.8).
- `cni: none`, `proxy.disabled: true`, node labels, `/var/local-path-provisioner` kubelet mount, registry-mirror
  patch for the eight registries → `${MIRROR}` (all reuse today's patch generation in `create-cluster.sh:78-151`).
- Cilium 1.20.0 from `scripts/manifests/cilium-1.20.0.tgz`, values in §2.
- Exports for later scripts: `CLOUDBOX_HOST_GATEWAY` (host as seen from nodes), `CLOUDBOX_API_ENDPOINT`.

**tbx backend.** Substrate-only path (`docs/SPEC.md:16-21` upstream): `tbx up cloudbox` from a checked-in
`scripts/substrate/cloudbox.tbx.yaml` (Talos `v1.13.8`, no `cni`, sizes from §4); wait for both nodes in
maintenance; `talosctl gen config` with our patches + `tbx manifests cloudbox mirrors` output merged;
`apply-config`, `bootstrap`, `kubeconfig` — our sequence, not tbx's. API endpoint is the CP node IP
(`172.30.<n>.2`); no `docker port` rewrite. Gateway is `172.30.<n>.1`. Destroy: `tbx down cloudbox --delete`.
`tbx` version is pinned in `scripts/versions.env` (`TBX_VERSION`) and `mise.toml`; install via
`brew install randax/tap/tbx` (mac) or the release tarball (Linux) — added to lab 00 prereqs and `dev-setup.sh`.

**Docker backend.** Unchanged except: it also publishes `80:30080` (ingress, §2) and its published NodePorts
are no longer referenced by lab text. Kubeconfig rewrite to `127.0.0.1:<port>` stays. Gateway stays
`host.docker.internal` / `10.5.0.1`.

**Windows/WSL2, Codespaces, CI:** Docker by construction — `CLOUDBOX_SUBSTRATE=docker` set in
`.devcontainer/devcontainer.json` and `bootstrap-test.yaml`. The fallback is a first-class path with its own
users, not an emergency exit.

**context-guard.sh:** additionally accept `https://172.30.[0-9]+.[0-9]+:6443` (and the tbx kubeconfig's
server string exactly) as a cloudbox endpoint.

## 2. Reachability: one hostname scheme

**Cilium values added on both substrates:** `ingressController.enabled=true`,
`ingressController.loadbalancerMode=shared`, `l2announcements.enabled=true`,
`ingressController.service.type=LoadBalancer` (tbx) / `NodePort` with `insecureNodePort=30080` (docker).
Cilium's `externalIPs`/`devices` left default; `k8sClientRateLimit` raised per Cilium's L2 docs.

**tbx only** (applied by the backend after Cilium): `CiliumLoadBalancerIPPool` `cloudbox` with
`172.30.<n>.200-172.30.<n>.239` and `CiliumL2AnnouncementPolicy` selecting all nodes, per talos-box
`internal/manifests/manifests.go:61-89`. The shared ingress Service therefore gets `.200`, which talos-box's
resolver already returns for every `*.cloudbox.k8s.test` name — no DNS work on our side.

**docker only:** `install.sh` (create step, not `--check`) maintains a marked block in `/etc/hosts`
(`# cloudbox-begin` … `# cloudbox-end`) mapping each hostname below to `127.0.0.1`; idempotent, removed by
`destroy-cluster.sh --purge`. Requires sudo once; `install.sh --check` verifies the block and fails with
`FAIL:` naming the missing lines. Windows/WSL2: the block goes in WSL's `/etc/hosts`; the Windows browser
needs `C:\Windows\System32\drivers\etc\hosts` too — documented in lab 00 with the exact lines printed by
`install.sh --print-hosts`.

**Hostnames** (`versions.env`, single `CLOUDBOX_DOMAIN="cloudbox.k8s.test"`; per-service `*_HOST_URL`
become `http://<name>.${CLOUDBOX_DOMAIN}`):

| service | host | backend Service |
|---|---|---|
| Gitea | `gitea.` | `gitea-http:3000` |
| ArgoCD | `argocd.` | `argocd-server:80` (insecure mode already on) |
| Portal | `portal.` | portal svc |
| Grafana | `grafana.` | grafana svc |
| RustFS S3 | `s3.` | rustfs svc:9000 (API; presigned URLs from the portal use this host) |
| RustFS console | `rustfs.` | rustfs console port |
| Backstage | `backstage.` | backstage svc:7007 (`app.baseUrl`, `backend.baseUrl`, CORS updated) |
| Zot | `zot.` | zot svc:5000 |
| Kourier / Knative | `*.kn.` | kourier gateway; Knative `config-domain` = `kn.cloudbox.k8s.test` |
| NATS mgmt | `nats.` | (HTTP monitoring only; client port stays NodePort/port-forward) |

Each lives as `gitops/components/<x>/ingress.yaml` (`ingressClassName: cilium`), in the component's
existing sync wave. Every `localhost:30xxx` and `127.0.0.1.sslip.io` reference in `lab/`, `solutions/`,
`gitops/`, `scripts/`, `slides/`, `.devcontainer/` is replaced; `scripts/check-consistency.sh` gains a check
that fails on any remaining `localhost:3` literal outside `scripts/substrate/docker.sh`.

Knative on Docker: wildcard hosts cannot go in `/etc/hosts`; lab 06 on Docker uses the two fixed
service names the lab creates (added to the hosts block), and the verifier accepts either.

## 3. Offline

`cloudbox-init.sh` unchanged for images; adds, when substrate is `tbx`, `tbx cache pull --talos-version
v1.13.8` (95 MB arm64 / 204 MB amd64, measured) and a `tbx doctor` run, and records both in the summary
line. `install.sh --check` asserts the raw image is present in `~/.talosbox/cache` for tbx. `images.txt`
gains the Cilium ingress/envoy images if not already present (check on implementation — Cilium's
ingress uses `cilium-envoy`, already pulled as a DaemonSet image in 1.20). Kagent's Ollama endpoint is
templated from `CLOUDBOX_HOST_GATEWAY` by `bootstrap-gitops.sh` (Kustomize patch), not hard-coded.

## 4. Sizing (tbx)

`cloudbox.tbx.yaml`: CP `memory: 4GiB, cpus: 4`; worker `memory: 8GiB, cpus: max(4, NCPU-2)`; disks 20 GB
sparse. Host floor stays 16 GB. **Unrehearsed**; the rehearsal in §5 records peak RSS at the module-10 end
state and the numbers land in `versions.env` (`TBX_CP_MEMORY`, `TBX_WORKER_MEMORY`) — the yaml is generated
from them, not a second source of truth. Docker limits unchanged.

## 5. Testing and the go-live gate

- `verify.sh`/`solve.sh` stay substrate-blind (kubectl/git/HTTP against hostnames). `lab/00` and `lab/01`
  branch on `~/.cloudbox/substrate` for the resource and node-identity checks only.
- CI (`bootstrap-test.yaml`): Docker substrate, gains the hosts block and ingress path; this is the
  CI-proven fallback. No tbx CI in 2026 (needs KVM runners).
- `check-consistency.sh`: new checks for `localhost:3xxxx` literals and for `versions.env` ↔ `mise.toml` `tbx` pin.
- **Go-live gate (by Aug 31):** one full 00→10 rehearsal on Apple Silicon over tbx, offline after prework,
  timings appended to `docs/REHEARSALS.md`, and one Docker rehearsal of the same content (ingress/hosts path)
  on the same machine. If the tbx rehearsal does not pass, the dispatcher default becomes `docker`
  (one line in `lib.sh`) and tbx stays available via `CLOUDBOX_SUBSTRATE=tbx`.
- `docs/HAZARDS.md` gets entries for: hard VM ceilings, L2 failover 40–50 s on macOS, `172.30.0.0/16` vs
  full-tunnel VPN (`tbx doctor` green while blackholed), `/etc/hosts` needing sudo, and `.200` resolving
  before anything owns it.

## 6. Work breakdown (for the plan)

1. Substrate split: move docker code, add dispatcher, `lib.sh` helpers, `~/.cloudbox/substrate`, context guard.
2. tbx backend + `cloudbox.tbx.yaml` + pins + prereqs (lab 00, dev-setup, mise).
3. Cilium values + tbx LB-IPAM/L2 objects + docker port-80 publish.
4. Ingress manifests for the ten services; Backstage/portal/Knative config changes.
5. Hosts block in install.sh; `--print-hosts`; devcontainer.
6. URL sweep across lab/solutions/gitops/scripts/slides + consistency check.
7. cloudbox-init tbx cache pull + install.sh checks; Kagent gateway templating.
8. CI workflow update; HAZARDS/REHEARSALS/README/PLAN updates; `docs/talos-box-vs-docker.md` decision note.
9. Rehearsals (tbx, then docker) and the gate decision.
