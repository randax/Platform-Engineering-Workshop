# Vendored: crossplane

| | |
|---|---|
| Source chart | `crossplane` **2.3.3** from https://charts.crossplane.io/stable |
| Core image | `xpkg.crossplane.io/crossplane/crossplane:v2.3.3` (chart default; xpkg.crossplane.io fronts GHCR — both `xpkg.crossplane.io/crossplane/crossplane:v2.3.3` and `ghcr.io/crossplane/crossplane:v2.3.3` verified 2026-07-13) |
| Files | `crossplane.yaml` (rendered) + `config/rbac.yaml`, `config/functions.yaml` (workshop additions) |

## Re-vendor

```sh
helm repo add crossplane-stable https://charts.crossplane.io/stable && helm repo update
cat > /tmp/crossplane-values.yaml <<'VALUES'
resourcesCrossplane:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    memory: 1Gi
resourcesRBACManager:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    memory: 256Mi
VALUES
helm template crossplane crossplane-stable/crossplane --version 2.3.3 \
  --namespace crossplane-system --no-hooks -f /tmp/crossplane-values.yaml > crossplane.yaml
```

## Workshop additions (`config/`, picked up via `directory.recurse: true`)

- `rbac.yaml` — aggregated ClusterRole (label
  `rbac.crossplane.io/aggregate-to-crossplane: "true"`) granting Crossplane
  rights over `postgresql.cnpg.io`, `batch` and the core resources lab 04's
  composition emits. Crossplane v2 composes arbitrary k8s resources directly
  and needs explicit RBAC per third-party API group.
- `functions.yaml` — pinned Function package
  `ghcr.io/crossplane-contrib/function-patch-and-transform:v0.10.7`
  (latest, 2026-06-05; manifest verified on GHCR 2026-07-13).

## Gotchas encoded in the Application manifest

- `ServerSideApply=true`: Crossplane CRDs exceed the 262KB annotation limit.
- `SkipDryRunOnMissingResource=true`: the `Function` CR's CRD is installed by
  this same sync.
- `ignoreDifferences` on Secret `/data` + `RespectIgnoreDifferences=true`:
  the chart ships `crossplane-root-ca` / `crossplane-tls-server` /
  `crossplane-tls-client` **empty**; the init container generates certs into
  them at runtime. Without the ignore rule, automated selfHeal fights it.

## OFFLINE WARNING

Crossplane's package manager fetches `spec.package` straight from the
registry — it does NOT use the node image cache, so pre-pulling onto nodes
does not cover the Function. Either enable this Application while internet is
available (recommended: during pre-flight), or mirror the xpkg into Zot and
point `config/functions.yaml` at
`zot.zot.svc.cluster.local:5000/crossplane-contrib/function-patch-and-transform:v0.10.7`.
