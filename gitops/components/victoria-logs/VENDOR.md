# Vendored: VictoriaLogs (single-node)

| | |
|---|---|
| Component | VictoriaLogs 1.52.0 — single-node log database (observability rework, issue #57 — replaces otel-lgtm's Loki) |
| Image | `docker.io/victoriametrics/victoria-logs:v1.52.0` — `sha256:47b820890d64c4575a2a0a46415dcd8a4fd59a0f1fcd6a377693d7aea639442e` (crane, 2026-08-11) |
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
- **The image is distroless from 1.52.0 on** — no shell, so `kubectl exec -- sh`
  into this pod does not work. Use `kubectl debug` (or read the logs) when
  troubleshooting. Nothing in the repo execs into it.

## Tag form: no `-victorialogs` suffix

Releases up to v1.24.0 carried a `-victorialogs` suffix (it disambiguated
VictoriaLogs releases inside the shared VictoriaMetrics repo). VictoriaLogs
moved to its own repo, `github.com/VictoriaMetrics/VictoriaLogs`, at v1.26.0 and
the suffix was dropped — `v1.24.0-victorialogs` is the last tag that ever had
it. The **repository is unchanged** (`docker.io/victoriametrics/victoria-logs`);
only the tag form is now bare, e.g. `v1.52.0`. Do not re-introduce the suffix:
there is no `v1.52.0-victorialogs`.

## Queried from Grafana via the **native** VictoriaLogs datasource

Grafana (see `../grafana/`) provisions VictoriaLogs through the native
`victoriametrics-logs-datasource` plugin, which is **baked into
`ghcr.io/randax/cloudbox-grafana`** at build time (`apps/grafana/Dockerfile`,
#65) — nothing is fetched at Grafana boot, so the offline rule holds. The
datasource `url` is the bare
`http://victoria-logs.observability.svc.cluster.local:9428`; the plugin appends
its own `/select/logsql/*` paths. The Loki-compatible shim
(`/select/loki/api/v1/*`) is no longer used by anything in this repo.

## Re-vendor

```sh
mise x crane@0.21.7 -- crane digest docker.io/victoriametrics/victoria-logs:v1.52.0
```

Keep the `image:` in `victoria-logs.yaml` and `scripts/images.txt` in lockstep
(`check-consistency.sh` enforces it).
