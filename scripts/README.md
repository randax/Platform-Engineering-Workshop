# CloudBox scripts

Everything needed to set up, run and recover the workshop platform. Attendees
are expected to read these scripts — they are part of the teaching material.
All version pins live in [`versions.env`](versions.env) (tools additionally in
the repo-root `mise.toml`); shared helpers live in [`lib.sh`](lib.sh).

## The attendee flow

### At home, before the workshop (good internet required)

```bash
./scripts/dev-setup.sh          # 1. install pinned CLI tools via mise
./scripts/cloudbox-init.sh      # 2. pre-pull ~7.5 GB of images + start the local mirror
./scripts/install.sh --check    # 3. pre-flight check — must be all green ✅
```

Conference WiFi carries keystrokes, not gigabytes: after `cloudbox-init.sh`
the workshop needs **no image downloads at the venue**.

### At the venue

```bash
./scripts/create-cluster.sh     # module 1: Talos cluster (tbx VMs or Docker) + Cilium
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
./scripts/kind-fallback.sh          # plan B if neither substrate will run
```

## Script reference

| Script | Purpose |
|---|---|
| `dev-setup.sh` | Install mise (with consent) + all pinned CLI tools, verify versions |
| `cloudbox-init.sh` | Pre-pull every pinned image from `images.txt`; start the `cloudbox-mirror` registry (localhost:5001) and copy cluster images into it |
| `install.sh --check` | Read-only pre-flight: platform, Docker resources, tools, pre-pulled images. Exit 0 = ready |
| `create-cluster.sh` | Substrate **dispatcher**: resolves tbx-or-docker, sources the backend, then runs the shared path — Talos config gen/apply/bootstrap (1 CP + 1 worker, CNI/kube-proxy off, registry mirrors) + Cilium via Helm. Persists the choice in `~/.cloudbox/substrate` |
| `substrate/docker.sh` | The **Docker backend**: `talosctl cluster create docker` (raised memory/CPU, published ports) and the marked `/etc/hosts` block that gives the hostname scheme somewhere to resolve |
| `substrate/tbx.sh` | The **talos-box backend**: `tbx up -f ~/.cloudbox/cloudbox.tbx.yaml` (rendered from `substrate/cloudbox.tbx.yaml.tmpl` + the `TBX_*` pins), then *our* Talos config — same patches as docker — plus the Cilium `LoadBalancerIPPool`/L2 policy and the wait for the ingress VIP |
| `destroy-cluster.sh` | `talosctl cluster destroy` + kubeconfig cleanup (this workshop's named entries, in both the pinned kubeconfig and `~/.kube/config`); `--purge-mirror` also removes the image mirror |
| `bootstrap-gitops.sh` | local-path-provisioner + Gitea (single-pod SQLite, push-to-create) + ArgoCD (vendored manifest, Application health check), then applies the Gitea and ArgoCD `Ingress` objects so both are reachable at their `*.cloudbox.k8s.test` names on either substrate |
| `seed-gitea.sh` | Force-push the local checkout to `cloudbox/platform` in Gitea (push-to-create) and apply the root app-of-apps Application |
| `catch-up.sh <module>` | Force-push module N's canonical `gitops/apps` + `gitops/components` state to Gitea, then run the module's post-steps; `--rebuild` for the full nuke-and-rebuild |
| `kind-fallback.sh` | Same cluster shape on kind + Cilium (loses the Talos content, gains robustness) |
| `check-consistency.sh` | Drift detection between everything that must agree: solutions↔catalog copies, deployed images ⊆ `images.txt`, `versions.env`↔`mise.toml`, devcontainer pins, `upstream.list` pin-sources, and that every `lab/`, `scripts/` and `solutions/` script touching a cluster passes the workshop-context guard. Offline; runs in CI on every push |
| `check-upstream.sh` | **Maintainer only, needs internet** — reports which pins have fallen *behind* upstream (`ok`/`patch`/`minor`/`major`). Reads `upstream.list`; never edits a pin. `--strict`, `--json`, `--only <name>` |
| `lib.sh` | Shared logging/helpers — sourced by every script |
| `context-guard.sh` | The workshop-context guard, defined once and shared with `lab/common.sh`. Sourcing it only *defines* `require_workshop_context`; each script calls it explicitly after its own create/rebuild step, because `create-cluster.sh` legitimately runs before the context exists |
| `versions.env` | Every version pin, in one place |
| `images.txt` | Every image the workshop uses, pinned, split into `[host]` and `[mirror]` sections |
| `upstream.list` | Where each pin comes from upstream (GitHub release/tag, Helm index, registry tag) and where it is currently written down — the manifest `check-upstream.sh` reads |
| `manifests/` | Vendored, pinned upstream manifests (ArgoCD install.yaml) so the venue needs no internet. local-path-provisioner is applied straight from `gitops/components/` — one copy, no drift |

## Why a local registry mirror?

The Talos "nodes" are Docker containers with their **own containerd inside** —
the host Docker image cache is invisible to them. `cloudbox-init.sh` therefore
runs a plain OCI registry (`cloudbox-mirror`, data in a Docker volume, so it
survives cluster rebuilds) and copies every cluster image into it with crane,
preserving repository paths and digests. Tag-only images are mirrored for your
machine's CPU architecture only; images pinned by digest are copied whole,
every architecture, because the pinned digest **is** the manifest index's
digest and the nodes resolve it against the mirror by that exact digest.
`create-cluster.sh` points the Talos
`machine.registries.mirrors` at it — with fallback to the real registries, so
a stale mirror can never break the cluster, it just costs bandwidth.

## Endpoints (after bootstrap)

One hostname scheme, both substrates — `*.cloudbox.k8s.test`:

| What | URL | Credentials |
|---|---|---|
| Gitea | http://gitea.cloudbox.k8s.test | `gitea_admin` / `cloudbox123` |
| ArgoCD | http://argocd.cloudbox.k8s.test | `admin` / see `bootstrap-gitops.sh` output |
| Cloudbox Console | http://portal.cloudbox.k8s.test | (module 08) |
| Grafana | http://grafana.cloudbox.k8s.test | (observability, on-demand) |
| RustFS console | http://rustfs.cloudbox.k8s.test | see `versions.env` |
| RustFS S3 endpoint | http://s3.cloudbox.k8s.test | see `versions.env` |
| Zot registry | http://zot.cloudbox.k8s.test | (enabled in module S2) |
| NATS monitoring | http://nats.cloudbox.k8s.test | (enabled in module S3) |
| Backstage | http://backstage.cloudbox.k8s.test | (presenter demo) |
| Knative services | `http://<name>-<namespace>.kn.cloudbox.k8s.test` | (enabled in module S1) |

On the **tbx** substrate talos-box's own resolver answers every one of these at the
cluster's ingress VIP (`172.30.<n>.200`). On the **Docker** substrate they come from a
marked `/etc/hosts` block; `./scripts/install.sh --print-hosts` prints it, and
`create-cluster.sh` writes it (one `sudo` prompt). The published-NodePort URLs on
localhost still work there as a fallback, but they exist on the Docker substrate only —
which is why no lab names them. Zot is the deliberate exception in the other direction:
attendees reach it by hostname, while the kubelet pulls from Zot's NodePort on the node
itself, which works the same way on both substrates.

Gitea's clone box in the web UI shows the **in-cluster** `ROOT_URL`
(`gitea-http.gitea.svc…`) — correct for ArgoCD, useless from your laptop. Clone from
`http://gitea.cloudbox.k8s.test/cloudbox/platform.git` (`GITEA_HOST_URL` in
`versions.env`) instead.

Which substrate you are on: `./scripts/install.sh --check`. To force one:
`CLOUDBOX_SUBSTRATE=docker` (or `=tbx`); the answer is remembered in
`~/.cloudbox/substrate` from the moment a cluster is created.

## Conventions

- `bash` with `set -euo pipefail`; every script has a usage header comment
- ✅/❌/⚠️ log lines via `lib.sh`; scripts are safe to re-run unless stated
- Anything that talks to a cluster calls `require_workshop_context` first and
  **refuses** on any context that is not this workshop's — there is no override.
  `destroy-cluster.sh` is the deliberate exception: it must work when the context
  is already wrong, and only ever touches named kubeconfig entries
- **The workshop has its own kubeconfig.** `mise.toml` sets
  `KUBECONFIG={{env.HOME}}/.kube/cloudbox.conf` for this repo, so the cluster lands in
  a file containing nothing else and a destroy leaves nothing to fall through to. No
  script sets or exports `KUBECONFIG` — that is mise's job alone, deliberately: an
  attendee who never activated mise must keep working exactly as before (everything in
  `~/.kube/config`), and forcing the pin from a script would split *them* into a shell
  and a script reading different files. The path is written down in exactly two places,
  `mise.toml` and `CLOUDBOX_KUBECONFIG` in `context-guard.sh`; check 9 of
  `check-consistency.sh` fails if they drift. `install.sh --check` reports which file is
  in effect, and fails outright if the cluster is in one file and the shell reads another
- **Everything is pinned** — no `:latest` anywhere. Bump pins in
  `versions.env` + `mise.toml` + `images.txt` together, and re-verify with
  `./scripts/install.sh --check` and CI

## Maintenance: keeping the pins honest

Two mechanized checks, deliberately split:

```bash
./scripts/check-consistency.sh   # offline: do our own files still agree?
./scripts/check-upstream.sh      # online:  has any pin fallen behind upstream?
mise run upstream                # the same thing, via mise
```

`check-upstream.sh` is a **maintainer** tool — it needs internet and is never
part of the attendee flow. It resolves every pin from where it actually lives
and compares it with the newest upstream version, so the "verified <date>,
re-verify before the conference" pass is a table you read, not an afternoon of
manual lookups. Adding or moving a pin means adding or fixing its row in
[`upstream.list`](upstream.list); `check-consistency.sh` fails if a row stops
resolving. Export `GITHUB_TOKEN` (or `GH_TOKEN`) to avoid the unauthenticated
GitHub API rate limit. Bumping a pin stays a deliberate decision — the script
reports, it never edits.

## Releasing the first-party images

The `ghcr.io/randax/cloudbox-*` entries in [`images.txt`](images.txt) are the
only pins **we** produce, and they are the one kind you never bump by hand:

1. Change something under `apps/`, merge to `main` with a conventional commit.
2. release-please keeps a release PR open with the next version and the
   changelog.
3. That PR also rewrites every pinned `cloudbox-*` ref in the repo —
   `images.txt`, the gitops components, the lab 04 example — through the
   `extra-files` list in `release-please-config.json`. The `x-release-please`
   start/end block comments around those refs are load-bearing — see
   [`images.txt`](images.txt) for the exact spelling. They are **full-line**
   comments on purpose: `check-consistency.sh` and the image gate read
   `images.txt` entries verbatim and only strip full-line comments.
4. Merging the PR tags `apps-v<version>` and publishes the multi-arch
   `:v<version>` images to GHCR.
5. **Still manual:** the first publish of a *new* image creates a private GHCR
   package, and its visibility cannot be set from CI — flip it to public at
   `https://github.com/users/randax/packages/container/<image>/settings`. Once
   per image, not per release.

Details, including the escape hatches for republishing without a release, are
in [`apps/README.md`](../apps/README.md#releasing-the-images).
