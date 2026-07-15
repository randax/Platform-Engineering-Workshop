# Vendored: Grafana

| | |
|---|---|
| Component | Grafana 12.4.5 — dashboards for the Victoria stack (observability rework, issue #57) |
| Image | `docker.io/grafana/grafana:12.4.5` — `sha256:26b8f35a9e4e4431995cf64c3f396505a4faf17bcfc19f9ed84943ec6bfd5ecd` (crane, 2026-07-15) |
| Source | Official image, https://hub.docker.com/r/grafana/grafana · docs https://grafana.com/docs/grafana/latest/ |
| Files | `grafana.yaml` (ConfigMap + Service + Deployment), `service-nodeport.yaml` (workshop addition) |

## Why not the Helm chart

The `grafana/grafana` chart brings a StatefulSet-or-Deployment toggle, a
sidecar that watches ConfigMaps for dashboards/datasources, an init-chown
container, RBAC, and a PDB. For a single-pod workshop Grafana with two static
datasources we hand-write the minimum: one Deployment, one Service, one
ConfigMap of provisioned datasources — same treatment as rustfs / nats.

## Config & curation

- **Two provisioned datasources** (ConfigMap `grafana-datasources` mounted
  read-only at `/etc/grafana/provisioning/datasources`, Grafana's file
  provisioning path — no sidecar, no plugin):
  - **VictoriaMetrics** as a **Prometheus** datasource (`isDefault: true`) →
    `http://victoria-metrics.observability.svc.cluster.local:8428`. VM speaks the
    Prometheus query API, so the built-in Prometheus datasource just works.
  - **VictoriaLogs** as a **Loki** datasource →
    `http://victoria-logs.observability.svc.cluster.local:9428`. VLogs exposes a
    Loki-compatible query API; we use the **built-in Loki type** rather than the
    dedicated VictoriaLogs plugin because that plugin would need an internet
    fetch at boot (offline rule). See `../victoria-logs/VENDOR.md` for the URL
    caveat (VLogs' Loki endpoints live under `/select/loki/api/v1/*`).
- **Anonymous read access** (`GF_AUTH_ANONYMOUS_ENABLED=true`, org role
  `Viewer`) — the workshop Grafana is open, matching otel-lgtm's posture. The
  login form is left available so an admin (default `admin`/`admin`, ephemeral
  lab) can still edit. Sign-up disabled; analytics/update checks disabled so
  nothing phones home at boot (offline rule); `GF_INSTALL_PLUGINS=""`.
- **NodePort 30031** (`service-nodeport.yaml`, a workshop addition, not
  upstream): browser reaches Grafana at `http://localhost:30031`. **Temporary
  port** — otel-lgtm's Grafana holds **30030** until it's retired in a later
  stage of issue #57, so this one uses 30031 to avoid a collision. Wired into
  the host via `NODEPORT_GRAFANA_V2` in `scripts/versions.env` and the
  `--exposed-ports` list in `scripts/create-cluster.sh`.
- **Ephemeral storage**: `/var/lib/grafana` and `/tmp` are `emptyDir` — the
  datasources are provisioned from the ConfigMap and `grafana.db` needn't
  survive a pod restart in a 4-hour lab (same rationale as otel-lgtm).
- **Security**: non-root (grafana's built-in uid/gid 472), all caps dropped,
  `readOnlyRootFilesystem` (only the two emptyDirs are writable),
  `seccompProfile: RuntimeDefault` — passes PodSecurity `restricted`.
- **Resources**: requests 100m / 128Mi, limit 512Mi.

## Re-vendor

```sh
mise x crane@0.21.7 -- crane digest docker.io/grafana/grafana:12.4.5
```

Keep the `image:` in `grafana.yaml` and `scripts/images.txt` in lockstep
(`check-consistency.sh` enforces it).
