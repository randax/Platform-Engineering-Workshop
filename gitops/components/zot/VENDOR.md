# Vendored: zot

| | |
|---|---|
| Source chart | `project-zot/zot` **0.1.122** from https://zotregistry.dev/helm-charts |
| App version | **v2.1.18** (`ghcr.io/project-zot/zot:v2.1.18` — the combined multi-arch image, amd64+arm64 verified on GHCR 2026-07-13; the per-arch `zot-linux-{amd64,arm64}` images also exist but are not needed) |
| File | `zot.yaml` (rendered) |

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
  --no-hooks -f /tmp/zot-values.yaml > zot.yaml
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
