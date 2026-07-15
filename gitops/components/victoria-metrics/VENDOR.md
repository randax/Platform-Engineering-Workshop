# Vendored: VictoriaMetrics (single-node)

| | |
|---|---|
| Component | VictoriaMetrics 1.147.0 — single-node TSDB (observability rework, [issue #57](https://github.com/) — replaces otel-lgtm's Prometheus) |
| Image | `docker.io/victoriametrics/victoria-metrics:v1.147.0` — `sha256:40ea45a6d14b6ad9f2f1fff597309d456ff9885d77d8d1da5fd559b251db9987` (crane, 2026-07-15) |
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
  port: OTLP metrics ingest (`POST /opentelemetry/v1/metrics`), Prometheus
  remote-write (`POST /api/v1/write`), and PromQL (`GET /api/v1/query`). No flag
  is needed to enable the OTLP endpoint; it is built in.
- **Data on a PVC** (`local-path`, 2 Gi) at `/victoria-metrics-data`
  (`-storageDataPath`). `Prune=false` so disabling the app doesn't wipe the TSDB
  mid-workshop — same protection as `rustfs-data` / `nats-jetstream`.
- **`-retentionPeriod=1`** (1 month, the default made explicit) — a sandbox,
  not prod.
- **Deployment strategy `Recreate`**: the data PVC is ReadWriteOnce, so a
  rolling update (two pods briefly) would deadlock on the volume.
- **Security**: non-root (uid/gid 1000), all caps dropped,
  `readOnlyRootFilesystem` (VM only writes the mounted data path),
  `seccompProfile: RuntimeDefault` — passes PodSecurity `restricted`. `fsGroup`
  makes kubelet chown the volume, so no initContainer is needed (same as nats).
- **Resources**: requests 50m / 256Mi, limit 512Mi (single-tenant lab).

## Re-vendor

Bump the tag, then re-resolve the digest:

```sh
mise x crane@0.21.7 -- crane digest docker.io/victoriametrics/victoria-metrics:v1.147.0
```

Keep the `image:` in `victoria-metrics.yaml` and the entry in
`scripts/images.txt` in lockstep (`check-consistency.sh` enforces it).
