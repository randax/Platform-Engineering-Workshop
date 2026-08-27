# Vendored: Grafana

| | |
|---|---|
| Component | Grafana 13.1.3 — dashboards for the Victoria stack (observability rework, issue #57) |
| Image | `docker.io/grafana/grafana:13.1.3` — `sha256:ab5cb380e3ff3172d6c8bd2e7cfd31cce977d2881b260e1f5bc089bf0b759b43` (crane, 2026-08-11; linux/amd64 + arm64 + arm). **Build input only** — the deployed image is `ghcr.io/randax/cloudbox-grafana`, so this ref lives in `apps/grafana/Dockerfile`, not `scripts/images.txt`. |
| Source | Official image, https://hub.docker.com/r/grafana/grafana · docs https://grafana.com/docs/grafana/latest/ |
| Files | `grafana.yaml` (ConfigMap + Service + Deployment), `service-nodeport.yaml` (workshop addition) |

Deployed image (first-party, built from `apps/grafana`):

<!-- x-release-please-start-version -->
```
ghcr.io/randax/cloudbox-grafana:v0.2.2
```
<!-- x-release-please-end-version -->

release-please rewrites that block (an `extra-files` entry in
`release-please-config.json`), so it cannot fall behind `grafana.yaml`.

## Why not the Helm chart

The `grafana/grafana` chart brings a StatefulSet-or-Deployment toggle, a
sidecar that watches ConfigMaps for dashboards/datasources, an init-chown
container, RBAC, and a PDB. For a single-pod workshop Grafana with two static
datasources we hand-write the minimum: one Deployment, one Service, one
ConfigMap of provisioned datasources — same treatment as rustfs / nats.

## Config & curation

- **Three provisioned datasources** (ConfigMap `grafana-datasources` mounted
  read-only at `/etc/grafana/provisioning/datasources`, Grafana's file
  provisioning path — no sidecar, no plugin) — one per store in the Victoria
  stack:
  - **VictoriaMetrics** via its **native datasource plugin**
    (`victoriametrics-metrics-datasource`, `isDefault: true`) →
    `http://victoria-metrics.observability.svc.cluster.local:8428` — the MetricsQL
    query editor. The plugin is **baked into the image** (`apps/grafana/Dockerfile`,
    #65), not fetched at boot (offline rule).
  - **VictoriaLogs** via its **native datasource plugin**
    (`victoriametrics-logs-datasource`) →
    `http://victoria-logs.observability.svc.cluster.local:9428` — full LogsQL + the
    VictoriaLogs Explore UX (the plugin takes the base URL and appends its own
    `/select/logsql/*` paths, so no `/select` suffix, unlike the old Loki shim).
    Also baked into the image.
  - Both native plugins load from `/opt/grafana-plugins` via `GF_PATHS_PLUGINS`,
    NOT the default `/var/lib/grafana/plugins` — the `data` emptyDir mounts over
    `/var/lib/grafana` and would shadow anything there.
  - **VictoriaTraces** as a **Jaeger** datasource (the Grafana catalog publishes
    no VictoriaTraces datasource at all — checked 2026-08-11) →
    `http://victoria-traces.observability.svc.cluster.local:10428/select/jaeger`.
    VTraces exposes a Jaeger-compatible query API, so we use the **built-in
    Jaeger type** (again no plugin, offline rule) — Jaeger-style trace search,
    not Tempo/TraceQL. See `../victoria-traces/VENDOR.md`.
- **The datasource `uid`s are a contract, not cosmetics** — `victoriametrics`,
  `victorialogs`, `victoriatraces`. The Console builds Grafana Explore deep-links
  by uid (`apps/portal/internal/web/grafana.go`; the trace link also hardcodes
  `"type": "jaeger"` for the VictoriaTraces pane, and `grafana_test.go` asserts
  it). Rename a uid or change the VictoriaTraces datasource type and every
  "View metrics"/"View traces" button in module 08/09 opens an empty Explore
  pane. Keep them stable across any Grafana or plugin bump.
- **`nodeGraph.enabled: true` on the VictoriaTraces (Jaeger) datasource** —
  turns on Grafana's built-in Node Graph tab, which renders a trace as a
  topology graph. For the module 09 capstone *this is the service map*
  (portal → uploader → broker → resizer) — without it the trace view is a
  waterfall only, and the capstone's "see the whole chain" beat is weaker. No
  plugin involved, so it works offline.
- **`jsonData.httpMethod: POST` on VictoriaMetrics** — long MetricsQL queries
  (the Console's deep-links carry the full query in the URL) exceed what a GET
  querystring handles comfortably.
- **Anonymous read access** (`GF_AUTH_ANONYMOUS_ENABLED=true`,
  `GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer`) — the workshop Grafana is open,
  workshop-grade on purpose. The login form is left available so an admin
  (default `admin`/`admin`, ephemeral lab) can still edit. Sign-up disabled
  (`GF_USERS_ALLOW_SIGN_UP=false`). **`GF_USERS_VIEWERS_CAN_EDIT=true` belongs
  to this group and is load-bearing:** the Viewer role does not carry the
  `datasources:explore` RBAC action, so without it Grafana 302s an anonymous
  `/explore?…panes=…` request to `/?redirectTo=/explore…` — the home page, with
  the Console's prefilled pane discarded. That breaks module 09 step 5 and every
  "open in Grafana" link the Console emits. Do not drop it; analytics and update
  checks disabled
  (`GF_ANALYTICS_REPORTING_ENABLED=false`,
  `GF_ANALYTICS_CHECK_FOR_UPDATES=false`) so nothing phones home at boot
  (offline rule); `GF_INSTALL_PLUGINS=""` **and**
  `GF_PLUGINS_PREINSTALL_DISABLED=true`.
- **`GF_PLUGINS_PREINSTALL_DISABLED=true` — the second half of the offline rule.**
  `GF_INSTALL_PLUGINS=""` only empties the *user* install list. Grafana separately
  background-installs a list of drilldown apps compiled into the binary
  (`grafana-{lokiexplore,pyroscope,exploretraces,metricsdrilldown}-app`; 13.1.3
  adds `elasticsearch` + `zipkin`, which the image already bundles). Offline those
  are six failing calls to grafana.com per pod start, and because the root
  filesystem is read-only each one lands as `level=error … read-only file system`
  in logs attendees are asked to read. Verified on 13.1.3: with the flag set,
  zero `plugin.backgroundinstaller` lines, zero errors, same 54 plugins loaded,
  all three datasources still provisioned.
- **NodePort 30030** (`service-nodeport.yaml`, a workshop addition, not
  upstream): browser reaches Grafana at `http://grafana.cloudbox.k8s.test`, the canonical
  observability port (freed when the old single-pod stack was retired —
  issue #57). Wired into the host via `NODEPORT_GRAFANA` in
  `scripts/versions.env` and the `--exposed-ports` list in
  `scripts/create-cluster.sh`.
- **Ephemeral storage**: `/var/lib/grafana` and `/tmp` are `emptyDir` — the
  datasources are provisioned from the ConfigMap, so a fresh pod re-derives its
  whole config and `grafana.db` needn't survive a restart in a 4-hour lab.
- **Security**: non-root (grafana's built-in uid/gid 472), all caps dropped,
  `readOnlyRootFilesystem` (only the two emptyDirs are writable),
  `seccompProfile: RuntimeDefault` — passes PodSecurity `restricted`.
- **Resources**: requests 100m / 128Mi, limit 512Mi.
- **Two Services on purpose.** `grafana` (ClusterIP, 3000→3000) is what anything
  in-cluster would talk to; `grafana-nodeport` (the workshop addition) carries
  nodePort 30030. Both select `app.kubernetes.io/{name,instance}: grafana` —
  those two labels are the selector contract, so keep them on the Deployment's
  pod template.
- **`strategy: type: Recreate`** — the default RollingUpdate would briefly run
  two Grafanas, and `grafana.db` lives on a per-pod emptyDir; Recreate keeps the
  single-writable-state story honest on a one-node cluster.
- **`fsGroup: 472`** alongside `runAsUser`/`runAsGroup` — the emptyDirs are
  group-owned by 472 so Grafana can write `/var/lib/grafana` under
  `readOnlyRootFilesystem`.
- **Liveness + readiness on `/api/health`** (:3000, 20s/10s and 10s/5s initial
  delay + period, 3s timeout). Grafana boots slowly on first start; shorter
  windows produce restart loops on a loaded laptop.
- **`imagePullPolicy: IfNotPresent`** — offline rule: never re-pull an image that
  `cloudbox-init.sh` already put on the node.
- **`app.kubernetes.io/version: "13.1.3"` on the Deployment** — a *hand-kept*
  label. Bump it with the base image (it is not release-please-managed; the
  `image:` ref inside the `x-release-please` block is, and it tracks our
  `cloudbox-grafana` release, not the Grafana version).

## Re-vendor

```sh
mise x crane@0.21.9 -- crane digest docker.io/grafana/grafana:13.1.3
```

Bumping the base image means editing the `FROM` line in `apps/grafana/Dockerfile`
(tag **and** digest) — `scripts/upstream.list` reads the `grafana` pin straight
out of that line, so keep it greppable as `FROM grafana/grafana:<x.y.z>@sha256:…`.

**Re-resolve both baked-in plugins at the same time.** They were pinned against a
specific Grafana version, and the catalog records a `grafanaDependency` range per
plugin version:

```sh
curl -s https://grafana.com/api/plugins/victoriametrics-metrics-datasource/versions \
  | jq -r '.items[] | "\(.version)\t\(.grafanaDependency)"' | head
curl -s https://grafana.com/api/plugins/victoriametrics-logs-datasource/versions \
  | jq -r '.items[] | "\(.version)\t\(.grafanaDependency)"' | head
```

At Grafana 13.1.3 (checked 2026-08-11): metrics **0.25.2** is the newest release
and its range ends in an unbounded `>=12.2.5`, so it covers 13.x unchanged. Logs
**0.29.0** is *held* — 0.30.1 and 0.31.0 exist and all three declare `>=10.4.0`,
so the hold is deliberate (keep the Grafana major bump a one-variable change),
not a compatibility limit. Both load `signature: valid, angularDetected: false`
on 13.1.3.

The deployed image is `ghcr.io/randax/cloudbox-grafana`, whose tag in
`grafana.yaml` and `scripts/images.txt` is rewritten by release-please inside the
`x-release-please` block comments — never hand-edit those refs. Stock
`docker.io/grafana/grafana` is deliberately **absent** from `scripts/images.txt`:
it is a CI build input, never pulled by a node.

## Guard-2 ignores

`scripts/check-vendor-drift.sh` requires every load-bearing knob in
`grafana.yaml` / `service-nodeport.yaml` to be mentioned somewhere above. One
extracted token is not a knob:

```curation
ignore apiVersion  the datasource-provisioning file's own schema version (`apiVersion: 1`, fixed by Grafana), not a workshop choice — it reads as a k8s apiVersion to the extractor
```
