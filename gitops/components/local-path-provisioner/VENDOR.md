# Vendored: local-path-provisioner

| | |
|---|---|
| Source | https://github.com/rancher/local-path-provisioner |
| Version | **v0.0.36** (latest release, 2026-05-08; verified 2026-07-13) |
| File | `local-path-storage.yaml` |

## Re-vendor

```sh
curl -sL -o local-path-storage.yaml \
  https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml
```

## Workshop curation applied (re-apply after re-vendoring)

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

Images used (all pinned, verified pullable 2026-07-13):
- `docker.io/rancher/local-path-provisioner:v0.0.36`
- `docker.io/library/busybox:1.37.0` (PVC setup/teardown helper pod)
