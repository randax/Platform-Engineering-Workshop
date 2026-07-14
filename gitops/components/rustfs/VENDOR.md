# Vendored: rustfs

| | |
|---|---|
| Source chart | `rustfs/rustfs` **0.8.0** from https://charts.rustfs.com |
| App version | **1.0.0-beta.8** (`docker.io/rustfs/rustfs:1.0.0-beta.8`, amd64+arm64, verified 2026-07-13) |
| Files | `rustfs.yaml` (rendered), `service-nodeport.yaml` (workshop addition) |

## Re-vendor

```sh
helm repo add rustfs https://charts.rustfs.com && helm repo update
cat > /tmp/rustfs-values.yaml <<'VALUES'
replicaCount: 1
image:
  initImage:
    repository: busybox
    tag: "1.37.0"
mode:
  standalone:
    enabled: true
  distributed:
    enabled: false
ingress:
  enabled: false
secret:
  rustfs:
    access_key: cloudbox
    secret_key: cloudbox123
config:
  rustfs:
    obs_log_directory: ""
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    memory: 512Mi
storageclass:
  name: local-path
  dataStorageSize: 2Gi
VALUES
helm template rustfs rustfs/rustfs --version 0.8.0 --namespace rustfs \
  --no-hooks -f /tmp/rustfs-values.yaml > rustfs.yaml
```

Values rationale:
- **standalone mode** (the chart defaults to a 4-pod distributed cluster!).
- `obs_log_directory: ""` disables the separate logs PVC → single 2Gi data
  PVC on `local-path`.
- `--no-hooks` drops the helm-test connection Pod (ArgoCD directory sources
  don't understand helm test hooks and would deploy it).
- init image pinned (`busybox:stable` upstream → `busybox:1.37.0`).
- Credentials `cloudbox`/`cloudbox123` are **workshop-grade and committed on
  purpose** (ephemeral lab sandbox); a comment in `rustfs.yaml` says the same.

After re-rendering, re-add the credentials comment above the Secret, and
re-add `argocd.argoproj.io/sync-options: Prune=false` to the `rustfs-data`
PVC: the chart's `helm.sh/resource-policy: keep` is ignored by ArgoCD, so
without the ArgoCD annotation disabling the app would prune the PVC and all
uploaded images.

Plan B (SeaweedFS, per RESEARCH.md switch triggers): re-vendor from the
`seaweedfs` chart with `allInOne.enabled=true` into this same directory and
keep the Service names stable for the labs.
