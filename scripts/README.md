# CloudBox scripts

Everything needed to set up, run and recover the workshop platform. Attendees
are expected to read these scripts — they are part of the teaching material.
All version pins live in [`versions.env`](versions.env) (tools additionally in
the repo-root `mise.toml`); shared helpers live in [`lib.sh`](lib.sh).

## The attendee flow

### At home, before the workshop (good internet required)

```bash
./scripts/dev-setup.sh          # 1. install pinned CLI tools via mise
./scripts/cloudbox-init.sh      # 2. pre-pull ~15-20 GB of images + start the local mirror
./scripts/install.sh --check    # 3. pre-flight check — must be all green ✅
```

Conference WiFi carries keystrokes, not gigabytes: after `cloudbox-init.sh`
the workshop needs **no image downloads at the venue**.

### At the venue

```bash
./scripts/create-cluster.sh     # module 1: Talos-in-Docker cluster + Cilium
./scripts/bootstrap-gitops.sh   # module 2: Gitea + ArgoCD (the GitOps engine)
./scripts/seed-gitea.sh         # module 2: push this repo into your cloud
```

From that point on the platform is built by **pushing git commits**, not by
running scripts: copy an Application manifest from `gitops/catalog/` into
`gitops/apps/`, commit, push to Gitea, watch ArgoCD converge.

### Recovery

```bash
./scripts/catch-up.sh 3             # jump to the end-state of module 3
./scripts/catch-up.sh 3 --rebuild   # nuclear: destroy + recreate + bootstrap
                                    # + seed + catch up (~10 min, pre-pulled)
./scripts/destroy-cluster.sh        # tear down the cluster (mirror survives)
./scripts/kind-fallback.sh          # plan B if Talos-in-Docker won't run
```

## Script reference

| Script | Purpose |
|---|---|
| `dev-setup.sh` | Install mise (with consent) + all pinned CLI tools, verify versions |
| `cloudbox-init.sh` | Pre-pull every pinned image from `images.txt`; start the `cloudbox-mirror` registry (localhost:5001) and copy cluster images into it |
| `install.sh --check` | Read-only pre-flight: platform, Docker resources, tools, pre-pulled images. Exit 0 = ready |
| `create-cluster.sh` | `talosctl cluster create docker` (Talos v1.13.6, 1 CP + 1 worker, CNI/kube-proxy off, registry mirrors) + Cilium via Helm |
| `destroy-cluster.sh` | `talosctl cluster destroy` + kubeconfig cleanup; `--purge-mirror` also removes the image mirror |
| `bootstrap-gitops.sh` | local-path-provisioner + Gitea (single-pod SQLite, push-to-create) + ArgoCD (vendored manifest, NodePort 30080, Application health check) |
| `seed-gitea.sh` | Force-push the local checkout to `cloudbox/platform` in Gitea (push-to-create) and apply the root app-of-apps Application |
| `catch-up.sh <module>` | Force-push module N's canonical `gitops/apps` + `gitops/components` state to Gitea, then run the module's post-steps; `--rebuild` for the full nuke-and-rebuild |
| `kind-fallback.sh` | Same cluster shape on kind + Cilium (loses the Talos content, gains robustness) |
| `check-consistency.sh` | Drift detection between everything that must agree: solutions↔catalog copies, deployed images ⊆ `images.txt`, `versions.env`↔`mise.toml`, devcontainer pins. Runs in CI on every push |
| `lib.sh` | Shared logging/helpers — sourced by every script |
| `versions.env` | Every version pin, in one place |
| `images.txt` | Every image the workshop uses, pinned, split into `[host]` and `[mirror]` sections |
| `manifests/` | Vendored, pinned upstream manifests (ArgoCD install.yaml) so the venue needs no internet. local-path-provisioner is applied straight from `gitops/components/` — one copy, no drift |

## Why a local registry mirror?

The Talos "nodes" are Docker containers with their **own containerd inside** —
the host Docker image cache is invisible to them. `cloudbox-init.sh` therefore
runs a plain OCI registry (`cloudbox-mirror`, data in a Docker volume, so it
survives cluster rebuilds) and copies every cluster image into it with crane,
preserving repository paths and digests. `create-cluster.sh` points the Talos
`machine.registries.mirrors` at it — with fallback to the real registries, so
a stale mirror can never break the cluster, it just costs bandwidth.

## Endpoints (after bootstrap)

| What | URL | Credentials |
|---|---|---|
| Gitea | http://localhost:30300 | `gitea_admin` / `cloudbox123` |
| ArgoCD | http://localhost:30080 | `admin` / see `bootstrap-gitops.sh` output |
| Zot registry | http://localhost:30500 | (enabled in module S2) |
| Kourier (Knative) | http://localhost:31080 | (enabled in module S1) |

## Conventions

- `bash` with `set -euo pipefail`; every script has a usage header comment
- ✅/❌/⚠️ log lines via `lib.sh`; scripts are safe to re-run unless stated
- **Everything is pinned** — no `:latest` anywhere. Bump pins in
  `versions.env` + `mise.toml` + `images.txt` together, and re-verify with
  `./scripts/install.sh --check` and CI
