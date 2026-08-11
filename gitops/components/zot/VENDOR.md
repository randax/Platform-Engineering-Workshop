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
command below. The image tag is the pin that matters and it is overridden
explicitly (see the curation list).

## Re-vendor

```sh
helm repo add project-zot https://zotregistry.dev/helm-charts && helm repo update
cat > /tmp/zot-values.yaml <<'VALUES'
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
VALUES
helm template zot project-zot/zot --version 0.1.122 --namespace zot \
  --no-hooks --set image.tag=v2.1.20 -f /tmp/zot-values.yaml > zot.yaml
```

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
- **`--set image.tag=v2.1.20`** (in the render command above, so it is not a
  hand-edit) — the zot *chart* releases lag the zot *server* releases: chart
  0.1.122 is current but still defaults to `image.tag: "v2.1.18"`. We track the
  server release, so the tag is overridden to the current patch. Re-check on
  every bump: when a chart appears whose `appVersion` already equals the tag we
  want, drop the `--set` instead of carrying it forward. `scripts/upstream.list`
  tracks the two independently (`zot` = image, `zot-chart` = chart).
