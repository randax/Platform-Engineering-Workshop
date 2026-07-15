# Vendored: VictoriaLogs (single-node)

| | |
|---|---|
| Component | VictoriaLogs 1.24.0 — single-node log database (observability rework, issue #57 — replaces otel-lgtm's Loki) |
| Image | `docker.io/victoriametrics/victoria-logs:v1.24.0-victorialogs` — `sha256:1ec31ddccc39dc9ead2607cddbf2829be1eb5ad39890e72bba26b359be20801d` (crane, 2026-07-15) |
| Source | Official image, https://hub.docker.com/r/victoriametrics/victoria-logs · docs https://docs.victoriametrics.com/victorialogs/ |
| Files | `victoria-logs.yaml` (PVC + Service + Deployment) |

## Why not the Helm chart

Same reasoning as VictoriaMetrics / nats: the `victoria-logs-single` chart pulls
in a StatefulSet, headless Service and PDB that a single-node workshop log store
doesn't need. Hand-written minimal (one Deployment, one PVC, one Service).

## Config & curation

- **Listens on :9428** — OTLP logs ingest (`POST /insert/opentelemetry/v1/logs`)
  and LogsQL query (`GET /select/logsql/query`) on one port.
- **Data on a PVC** (`local-path`, 2 Gi) at `/victoria-logs-data`
  (`-storageDataPath`), `Prune=false` (same protection as the other stateful
  components).
- **`-retentionPeriod=7d`** — VictoriaLogs default made explicit; plenty for a
  4-hour lab.
- **Deployment strategy `Recreate`** (RWO PVC), same as VictoriaMetrics.
- **Security**: non-root (uid/gid 1000), all caps dropped,
  `readOnlyRootFilesystem`, `seccompProfile: RuntimeDefault`; `fsGroup` chowns
  the volume so no initContainer — identical hardening to nats / VictoriaMetrics.
- **Resources**: requests 50m / 256Mi, limit 512Mi.

## Caveat: queried from Grafana via the built-in **Loki** datasource

Grafana (see `../grafana/`) provisions VictoriaLogs as a **Loki-type**
datasource, not a dedicated one. Why:

- A dedicated `victoriametrics-logs-datasource` Grafana plugin exists, but
  installing it needs an internet fetch at Grafana boot — that breaks the
  workshop's **offline rule** (everything pre-pulled, nothing fetched at the
  venue). We won't ship an internet-at-boot plugin.
- VictoriaLogs therefore rides Grafana's **built-in Loki datasource** (core, no
  plugin), because VLogs implements a Loki-compatible query API.
- The datasource `url` is `http://victoria-logs.observability.svc.cluster.local:9428`
  as specified for issue #57. **Caveat:** VictoriaLogs serves its Loki-compatible
  query endpoints under the `/select/loki/api/v1/*` prefix, so if the Loki
  datasource doesn't resolve LogsQL/Loki queries against the bare `:9428` base,
  point its URL at `.../select` (Grafana then appends `/loki/api/v1/...`). This
  is the one spot in the Victoria stack that may need a per-Grafana-version
  nudge; revisit when the stack graduates from coexistence to replacing
  otel-lgtm.

## Re-vendor

```sh
mise x crane@0.21.7 -- crane digest docker.io/victoriametrics/victoria-logs:v1.24.0-victorialogs
```

Keep the `image:` in `victoria-logs.yaml` and `scripts/images.txt` in lockstep
(`check-consistency.sh` enforces it).
