# Vendored: crossplane

| | |
|---|---|
| Source chart | `crossplane` **2.3.4** from https://charts.crossplane.io/stable |
| Core image | `xpkg.crossplane.io/crossplane/crossplane:v2.3.4` — `sha256:cea30c75198e8cee8e9a4fcb003b158750d345ca91831876de38989c11cbf94c`, linux/amd64 + linux/arm64 verified 2026-08-11 (chart default; xpkg.crossplane.io fronts GHCR — `ghcr.io/crossplane/crossplane:v2.3.4` resolves to the same digest, verified 2026-08-11) |
| Files | `crossplane.yaml` (rendered) + `config/rbac.yaml`, `config/functions.yaml` (workshop additions) |

## Re-vendor

The recipe lives **once**, in the `curation` block further down this file —
`scripts/check-vendor-drift.sh` runs it, so it cannot rot into a stale copy of
itself. Re-vendoring is: reproduce the file with that recipe, re-apply the
curation below, then `./scripts/check-vendor-drift.sh --only crossplane`.

### The re-render gate

`scripts/check-vendor-drift.sh` re-runs the `helm template` below — values and
all — and diffs the result against `crossplane.yaml`. All of this component's
curation is *in the values*, so the render has no post-hoc edits; the single
`allow` line is inert helm-4 whitespace (the file was rendered with helm 3, and
helm 4 lays out blank lines differently). Any other hunk means the chart changed
under a value we set, or someone hand-edited the rendered file.

```curation
render crossplane.yaml
chart     crossplane
repo      https://charts.crossplane.io/stable
version   2.3.4
release   crossplane
namespace crossplane-system
flags     --no-hooks
values
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

# --- accepted curation: one line per diff hunk (id, then why) ---
allow  crossplane.yaml  39cdd0de  helm 4 emits a blank line before each `---`; this file was rendered with helm 3. Inert whitespace, no manifest changes — it disappears the next time the file is re-vendored with the pinned helm 4.2.3
```

## Workshop additions (`config/`, picked up via `directory.recurse: true`)

- `rbac.yaml` — aggregated ClusterRole (label
  `rbac.crossplane.io/aggregate-to-crossplane: "true"`) granting Crossplane
  rights over `postgresql.cnpg.io` (`*`), `batch` (`jobs`, `cronjobs`) and the
  core resources lab 04's composition emits — `configmaps`, `secrets`,
  `services`, `serviceaccounts`, `persistentvolumeclaims`. Crossplane v2
  composes arbitrary k8s resources directly and needs explicit RBAC per
  third-party API group; widening this list is a privilege decision, so it is
  written out here rather than left to the YAML.
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
