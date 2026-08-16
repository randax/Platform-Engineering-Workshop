# Vendored: VictoriaMetrics (single-node)

| | |
|---|---|
| Component | VictoriaMetrics 1.149.0 — single-node TSDB (observability rework, [issue #57](https://github.com/) — replaces otel-lgtm's Prometheus) |
| Image | `docker.io/victoriametrics/victoria-metrics:v1.149.0` — `sha256:13b8951e35bb3589626816538483127785a9d8b53f9f5123769db0fcab1d961f` (crane, 2026-08-11; linux/amd64 + arm64 + arm + 386 + ppc64le) |
| Source | Official image, https://hub.docker.com/r/victoriametrics/victoria-metrics · docs https://docs.victoriametrics.com |
| Files | `victoria-metrics.yaml` (PVC + Service + Deployment) |

## Why not the Helm chart

The `victoria-metrics-single` Helm chart renders a StatefulSet with a
ServiceMonitor, scrape-config plumbing, PodDisruptionBudget and a headless
Service — all overkill for a single-tenant workshop TSDB. We hand-write the
minimal equivalent (one Deployment, one PVC, one Service) so attendees can read
the whole thing, matching the rustfs / nats treatment.

## Config & curation

- **Listens on :8428** — VictoriaMetrics single-node serves everything on one
  port: OTLP metrics ingest (`POST /opentelemetry/v1/metrics` — this is what the
  OTel Collector's `otlphttp/metrics` exporter targets), Prometheus remote-write
  (`POST /api/v1/write`, documented but unused here), and PromQL
  (`GET /api/v1/query`). No flag is needed to enable the OTLP endpoint; it is
  built in.
- **`-opentelemetry.usePrometheusNaming=true`** is what makes OTLP metric names
  come out as `k8s_pod_cpu_usage` / `k8s_pod_memory_working_set_bytes` — the
  names `apps/portal/internal/metrics/prom.go` and the CI sparkline assertion
  hard-code. 1.149.0 carries a bugfix to OTLP `Unit`-suffix handling, so the
  re-pin was checked by pushing the exact names+units we emit into 1.147.0 and
  1.149.0 side by side: the resulting `__name__` sets are identical.
- **Data on a PVC** (`local-path`, `2Gi`) at `/victoria-metrics-data`
  (`-storageDataPath`). `argocd.argoproj.io/sync-options: Prune=false` so
  disabling the app doesn't wipe the TSDB
  mid-workshop — same protection as `rustfs-data` / `nats-jetstream`.
- **`-retentionPeriod=1`** (1 month, the default made explicit) — a sandbox,
  not prod.
- **Deployment strategy `Recreate`**: the data PVC is ReadWriteOnce, so a
  rolling update (two pods briefly) would deadlock on the volume.
- **Security**: non-root (uid/gid 1000), all caps dropped,
  `readOnlyRootFilesystem` (VM only writes the mounted data path),
  `seccompProfile: RuntimeDefault` — passes PodSecurity `restricted`. `fsGroup`
  makes kubelet chown the volume, so no initContainer is needed (same as nats).
- **Probes**: liveness and readiness are both `GET /health` on :8428 — it
  answers once the TSDB is open, which is what "Ready" should mean here.
- **Resources**: requests 50m / 256Mi, limit 512Mi (single-tenant lab).

## Re-vendor

Bump the tag, then re-resolve the digest:

```sh
mise x crane@0.21.9 -- crane digest docker.io/victoriametrics/victoria-metrics:v1.149.0
```

This is a hand-written component, so "re-vendor" means: diff the new binary's
own flag list against the old one and confirm every flag we pass still exists
with the same default —

```sh
docker run --rm --entrypoint /victoria-metrics-prod \
  docker.io/victoriametrics/victoria-metrics:v1.149.0 --help 2>&1
```

— then boot it with our exact args under the same hardening
(`--read-only --tmpfs /tmp --user 1000:1000 --cap-drop ALL`) and curl the paths
above. 1.147.0 → 1.149.0: zero flags removed, one added (`-maxBackfillAge`),
all four of ours byte-identical in help text and default.

Keep the `image:` in `victoria-metrics.yaml` and the entry in
`scripts/images.txt` in lockstep (`check-consistency.sh` enforces it).
