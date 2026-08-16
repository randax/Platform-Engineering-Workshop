# Vendored: zot

| | |
|---|---|
| Source chart | `project-zot/zot` **0.1.122** from https://zotregistry.dev/helm-charts (still the newest chart, 2026-08-11 — the chart did **not** move for this image bump) |
| App version | **v2.1.20** (`ghcr.io/project-zot/zot:v2.1.20`, `sha256:542e25be4d32e7879c0cfad93492a93c81b1e059cbd2d30d485d4bd567318234` — the combined multi-arch image, linux/amd64 + linux/arm64 verified on GHCR 2026-08-11; the per-arch `zot-linux-{amd64,arm64}` images also exist but are not needed) |
| File | `zot.yaml` (rendered) |

Chart 0.1.122 still declares `appVersion: v2.1.18`, so the render's
`app.kubernetes.io/version` labels say `v2.1.18` while the container runs
`v2.1.20`. That mismatch is the chart's, not ours: the labels are left exactly
as `helm template` emits them so the file stays byte-reproducible from the
`curation` block at the bottom of this file. The image tag is the pin that
matters and it is overridden explicitly (see the curation list).

## Re-vendor

The recipe lives **once**, in the `curation` block at the bottom of this file —
`scripts/check-vendor-drift.sh` runs it, so it cannot rot into a stale copy of
itself. Re-vendoring is: reproduce the file with that recipe, re-apply the
curation below, then `./scripts/check-vendor-drift.sh --only zot`.

Config rationale:
- **Anonymous read/write on every repository** — workshop-grade; BuildKit
  pushes and kubelets pull without credentials.
- search + ui extensions enabled (the combined image ships them) → visible
  win at http://localhost:30500.
- Renders a StatefulSet with a 5Gi volumeClaimTemplate on `local-path`.
- Reachable as `zot.zot.svc.cluster.local:5000` in-cluster (BuildKit pushes
  with `registry.insecure=true`; Talos machine config must mirror/allow this
  registry as insecure for kubelet pulls — cluster-script side).

Workshop curation applied after rendering (re-apply after re-vendoring):
- **Added container resource requests 50m/128Mi** (the chart renders
  `resources: null`) — same small-cluster requests convention as the other
  components, so the scheduler accounts for the registry.
- **`--set image.tag=v2.1.20`** (a `flags` entry in the render recipe below, so
  it is not a hand-edit) — the zot *chart* releases lag the zot *server*
  releases: chart 0.1.122 is current but still defaults to
  `image.tag: "v2.1.18"`. We track the
  server release, so the tag is overridden to the current patch. Re-check on
  every bump: when a chart appears whose `appVersion` already equals the tag we
  want, drop the `--set` instead of carrying it forward. `scripts/upstream.list`
  tracks the two independently (`zot` = image, `zot-chart` = chart).

### The same list, machine-readable

`scripts/check-vendor-drift.sh` re-runs the `helm template` below — chart,
version, flags and values — and diffs the result against the vendored file.
Every hunk needs an `allow` line: an unlisted hunk fails (undocumented
curation, or the chart moved under us) and an `allow` line whose hunk has
**disappeared** fails too, because that is a curation lost in a re-vendor. The
prose above is the *why*; these lines are only the bookkeeping. `--update`
rewrites the ids; you still write the label.

Note the `values` here are the *whole* input: keeping them in the block rather
than in a `/tmp` heredoc is what makes the render reproducible by a machine.

```curation
render zot.yaml
chart     zot
repo      https://zotregistry.dev/helm-charts
version   0.1.122
release   zot
namespace zot
flags     --no-hooks --set image.tag=v2.1.20
values
  service:
    type: NodePort
    port: 5000
    nodePort: 30500
  mountConfig: true
  configFiles:
    config.json: |-
      {
        "storage": { "rootDirectory": "/var/lib/registry" },
        "http": {
          "address": "0.0.0.0",
          "port": "5000",
          "accessControl": {
            "repositories": {
              "**": {
                "anonymousPolicy": ["read", "create", "update", "delete", "detectManifestCollision"],
                "defaultPolicy": []
              }
            }
          }
        },
        "log": { "level": "info" },
        "extensions": {
          "search": { "enable": true },
          "ui": { "enable": true }
        }
      }
  persistence: true
  pvc:
    create: true
    storage: 5Gi
    storageClassName: local-path
  serviceHeadless:
    # StatefulSet needs a serviceName to be valid on k8s < 1.35 — the chart
    # only sets it when the headless service is enabled.
    enabled: true
    port: 5000

# --- accepted curation: one line per diff hunk (id, then why) ---
allow  zot.yaml  39cdd0de  helm 4 emits a blank line before each `---`; this file was rendered with helm 3. Inert whitespace, no manifest changes — it disappears the next time the file is re-vendored with the pinned helm 4.2.3
allow  zot.yaml  3c282743  the comment above the added requests
allow  zot.yaml  f688b02e  50m/128Mi requests replacing the chart's `resources: null`
```
