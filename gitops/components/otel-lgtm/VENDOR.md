# Vendored: otel-lgtm

| | |
|---|---|
| Source | https://github.com/grafana/docker-otel-lgtm (`k8s/lgtm.yaml`) |
| Image | **docker.io/grafana/otel-lgtm:0.29.0** (release 2026-07-13; multi-arch amd64+arm64, verified on Docker Hub) |
| File | `otel-lgtm.yaml` |

## Re-vendor

Upstream manifest (reference only — ours is adapted, easier to edit in place):

```sh
curl -sL https://raw.githubusercontent.com/grafana/docker-otel-lgtm/v0.29.0/k8s/lgtm.yaml
```

## Workshop curation applied

1. Pinned the image (upstream uses `:latest`) and added `namespace: observability`.
2. Service trimmed to the ports the workshop uses: Grafana 3000, OTLP
   4317 (gRPC) / 4318 (HTTP), Prometheus 9090.
3. Grafana anonymous access (org role Admin, login form disabled) pinned via
   `GF_AUTH_*` env — the image's default, made explicit.
4. Modest resources: requests 200m / 1Gi, limit 2Gi (research budget: the
   whole pod idles around 1 GB).
5. `strategy: Recreate` (single replica with in-container state).

Storage is emptyDir on purpose: metrics/logs/traces don't need to survive pod
restarts in a 4-hour lab.
