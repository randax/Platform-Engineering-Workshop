# Vendored: local-path-provisioner

| | |
|---|---|
| Source | https://github.com/rancher/local-path-provisioner |
| Version | **v0.0.37** (latest release; verified 2026-08-11) |
| File | `local-path-storage.yaml` |

## Re-vendor

The recipe lives **once**, in the `curation` block at the bottom of this file —
`scripts/check-vendor-drift.sh` runs it, so it cannot rot into a stale copy.
Re-vendoring is: run that `fetch` URL into the file, re-apply the curation
below, then `./scripts/check-vendor-drift.sh --only local-path-provisioner`.

## Upstream change in v0.0.37 — the Deployment now has probes

v0.0.37's entire upstream diff is a health server: a `health` container port
(8080), `HEALTH_PORT=8080`, and startup (`/health`, 5s delay, 5s period,
12 failures ≈ 60s grace), liveness (`/health`) and readiness (`/ready`) probes.
That matters here because this is the **wave-0 gate**:
`scripts/bootstrap-gitops.sh` installs this component imperatively and then
`wait_rollout`s it before Gitea (whose PVC needs the storage class), so the
Deployment now only reports Ready once its health server answers. A slow or
unhappy health server stalls everything after module 02 — loud and early, but
worth watching in rehearsal.

## Workshop curation applied (re-apply after re-vendoring)

0. **Namespace label `pod-security.kubernetes.io/enforce: privileged`** — the
   provisioner's helper pods mount hostPath volumes and Talos enforces PSA
   `baseline` cluster-wide; without the label every PVC hangs Pending.
1. **StorageClass `local-path` is the cluster default** — added annotation
   `storageclass.kubernetes.io/is-default-class: "true"`.
2. **Talos path**: `nodePathMap` changed from `/opt/local-path-provisioner`
   to `/var/local-path-provisioner`. Talos' root FS is immutable; only `/var`
   is writable, and the path must be bind-mounted into the kubelet via
   `machine.kubelet.extraMounts` in the machine config (cluster scripts).
3. **Pinned the helper pod image** `docker.io/library/busybox` →
   `docker.io/library/busybox:1.37.0` (upstream ships it unpinned; an
   unpinned tag silently defeats image pre-pulling).
4. **Added container resource requests 25m/32Mi** to the provisioner
   Deployment (upstream ships none) — same small-cluster requests
   convention as the other components, no limits.

### The same list, machine-readable

`scripts/check-vendor-drift.sh` re-fetches the upstream file and diffs it
against ours. Every hunk must have an `allow` line here; an unlisted hunk fails
(undocumented curation, or upstream moved under us), and an `allow` line whose
hunk has *disappeared* fails too — that is a curation lost in a re-vendor,
which is how the PSA label went missing once already. The prose above is the
why; these lines are only the bookkeeping that keeps the prose honest.
`--update` rewrites the ids for you; you still write the label.

```curation
render local-path-storage.yaml
fetch  https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml

# --- accepted curation: one line per diff hunk (id, then why) ---
allow  local-path-storage.yaml  655d7dcf  curation 0 — `pod-security.kubernetes.io/enforce: privileged` on the namespace (helper pods mount hostPath; without it every PVC hangs Pending)
allow  local-path-storage.yaml  c098d56d  curation 4 — 25m/32Mi requests on the provisioner container (upstream ships none)
allow  local-path-storage.yaml  0041183a  curation 1 — `storageclass.kubernetes.io/is-default-class` on the local-path StorageClass
allow  local-path-storage.yaml  5e387756  curation 2 — the comment explaining why nodePathMap moved to /var (Talos root FS is immutable)
allow  local-path-storage.yaml  be0e5885  curation 2 — nodePathMap /opt/local-path-provisioner → /var/local-path-provisioner
allow  local-path-storage.yaml  2d6953aa  curation 3 — helper pod image pinned to busybox:1.37.0 (upstream ships it unpinned)
```

Images used (all pinned, verified pullable 2026-08-11):
- `docker.io/rancher/local-path-provisioner:v0.0.37`
  (`sha256:e757967a5ec338f6a9b371c5a9688bedaa8c3578ea3dd4db329ea0084be0a86f`)
- `docker.io/library/busybox:1.37.0` (PVC setup/teardown helper pod) — unchanged;
  upstream still ships the helper pod unpinned.
