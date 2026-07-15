# Vendored: VictoriaTraces (single-node)

| | |
|---|---|
| Component | VictoriaTraces 0.9.4 — single-node trace database (observability rework, [issue #57](https://github.com/randax/Platform-Engineering-Workshop/issues/57) — replaces otel-lgtm's Tempo) |
| Image | `docker.io/victoriametrics/victoria-traces:v0.9.4` — `sha256:de1f0ce3916692236a711b58e48c65cc4138bfaa4e36324cfa25206e5485b187` (crane, 2026-07-15; linux/amd64 + arm64) |
| Source | Official image, https://hub.docker.com/r/victoriametrics/victoria-traces · docs https://docs.victoriametrics.com/victoriatraces/ |
| Files | `victoria-traces.yaml` (PVC + Service + Deployment) |

## Why VictoriaTraces (chosen over Tempo)

Unifies the observability stack under one vendor — VictoriaMetrics + VictoriaLogs
+ **VictoriaTraces** — instead of bolting Grafana Tempo onto a Victoria stack.
It's built *on top of* VictoriaLogs internally (spans are stored as structured
logs), so it inherits the same lightweight single-node story.

It's new (v0.9.x), so the two workshop-critical risks are managed explicitly:

- **Offline** — pinned by digest (never `:latest`), on `scripts/images.txt`.
- **Grafana** — VictoriaTraces exposes a **Jaeger-compatible query API**, *not*
  Tempo/TraceQL. So Grafana queries it with the **built-in Jaeger datasource** —
  no plugin, works offline — exactly the trick VictoriaLogs uses with the Loki
  datasource. (A native VictoriaTraces Grafana datasource plugin exists; vendoring
  it for a nicer trace UX is a tracked stretch goal on #57.)

## Config & curation

- **Listens on :10428** — one port for everything:
  - OTLP traces ingest → `POST /insert/opentelemetry/v1/traces` (the OTel
    Collector's `otlphttp/traces` exporter targets this).
  - Jaeger Query API → `GET /select/jaeger/api/*` — Grafana's Jaeger datasource
    URL is `http://victoria-traces.observability.svc.cluster.local:10428/select/jaeger`.
- **Data on a PVC** (`local-path`, 2 Gi) at `/victoria-traces-data`
  (`-storageDataPath`). `Prune=false` so disabling the app doesn't wipe traces
  mid-workshop — same protection as `victoria-logs` / `nats-jetstream`.
- **`-retentionPeriod=7d`** — a sandbox, not prod.
- **Deployment strategy `Recreate`**: the data PVC is ReadWriteOnce, so a rolling
  update (two pods briefly) would deadlock on the volume.
- **Security**: non-root (uid/gid 1000), all caps dropped, `readOnlyRootFilesystem`
  (VT only writes the mounted data path + `/tmp` emptyDir), `seccompProfile:
  RuntimeDefault`. `fsGroup` chowns the volume so no initContainer is needed
  (same as victoria-logs).
- **Resources**: requests 50m / 256Mi, limit 512Mi (single-tenant lab).

## Re-vendor

Bump the tag, then re-resolve the digest:

```sh
mise x crane@0.21.7 -- crane digest docker.io/victoriametrics/victoria-traces:v0.9.4
```

Keep the `image:` in `victoria-traces.yaml` and the entry in `scripts/images.txt`
in lockstep (`check-consistency.sh` enforces it).
