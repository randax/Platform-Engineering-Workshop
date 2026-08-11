# Vendored: OpenTelemetry Collector (contrib)

| | |
|---|---|
| Component | OTel Collector 0.158.0 — the collection layer of the Victoria stack ([issue #57](https://github.com/randax/Platform-Engineering-Workshop/issues/57), Stage 2 — closes the "only 3 apps push anything" gap) |
| Image | `docker.io/otel/opentelemetry-collector-contrib:0.158.0` — `sha256:c5918f78992ee73b0d6f0e599423ac5ec52dd5d9726733114d6eca53d5a32ed5` (crane, 2026-08-11; linux/amd64 + arm64) |
| Source | Official image, https://hub.docker.com/r/otel/opentelemetry-collector-contrib · docs https://opentelemetry.io/docs/collector/ |
| Files | `rbac.yaml`, `collector-agent.yaml` (DaemonSet), `collector-gateway.yaml` (Deployment + Service) |

## Why plain manifests, not the OTel Operator

The Operator's admission webhook needs TLS, which in practice drags in
cert-manager (another operator + CRDs + ~3 pods) against the ~10-tool budget and
the module-09 RAM ceiling. Its headline feature — the Target Allocator that
shards Prometheus scrapes across many collectors — is pointless on a single-node
cluster. So we deploy the collector directly as a ConfigMap + DaemonSet +
Deployment + RBAC: fewer moving parts, and a manifest set an attendee can read
top to bottom. (Decision recorded on issue #57.)

## Why the *contrib* image

The core `otelcol` image lacks `filelog`, `kubeletstats`, and `k8s_cluster`.
Those three receivers are exactly the collection gap we're closing, so we need
`opentelemetry-collector-contrib`.

## Topology & config

Two collectors, split by what each signal needs:

- **agent (DaemonSet, one per node)** — node-local signals:
  - `filelog` tails `/var/log/pods/*/*/*.log` (host mount, read-only). Talos runs
    containerd → CRI log format; the `container` operator parses it and derives
    `k8s.namespace.name` / `k8s.pod.name` / `k8s.container.name` from the path, so
    no `k8sattributes` processor (and its extra RBAC) is needed for stream labels.
    Offsets persist in a hostPath (`/var/lib/otelcol`) via the `file_storage`
    extension. Runs as **root** — pod log files are root-owned; it only reads.
  - `kubeletstats` scrapes the local kubelet at `https://$HOST_IP:10250` with
    `auth_type: serviceAccount` (the kubelet authorizes the SA token against
    `nodes/stats`), `insecure_skip_verify` (Talos-issued serving cert).
  - Exports: metrics → VM, logs → VLogs.
- **gateway (Deployment, replicas: 1)** — cluster singletons:
  - `k8s_cluster` — object-state metrics (must be singleton or it double-counts).
  - `prometheus` — two scrape jobs: `kubernetes-pods` (annotation-based:
    `prometheus.io/scrape: "true"`, honouring `prometheus.io/port` + `…/path`)
    and `cnpg` (CloudNativePG instances by their `cnpg.io/cluster` label on
    :9187 — they carry no prometheus.io annotations, and annotating the Cluster
    specs would churn every `solutions/` copy). NB: literal relabel replacement
    refs are written `$$1`/`$$2` because the collector expands `$…` as env vars —
    `$$` escapes to a literal `$`.
  - `otlp` (4317/4318) — the apps (portal/uploader/resizer) push their OTLP
    traces + metrics here; it replaced otel-lgtm's OTLP endpoint. Exposed via the
    `otel-collector` Service.
  - `spanmetrics` + `servicegraph` **connectors** — they read the trace stream and
    emit metrics into the metrics pipeline: `span.calls` / `span.duration` (RED)
    and `traces_service_graph_request_{total,client,server}` (the edges of the
    module-09 service map). `bootstrap-test.yaml` asserts both series families
    exist, so they are load-bearing for CI as well as for the capstone.
  - Exports: traces → VTraces, metrics → VM, logs → VLogs.

Both export over plain HTTP (`otlphttp`, explicit full `*_endpoint` paths) to
`victoria-metrics:8428/opentelemetry/v1/metrics` and
`victoria-logs:9428/insert/opentelemetry/v1/logs`. `VL-Stream-Fields` tells
VictoriaLogs which resource attributes partition the streams (its Loki-label
equivalent).

## Curation

- **RBAC is read-only** — one ServiceAccount shared by both collectors; the
  ClusterRole is the union of what k8s_cluster / kubeletstats / prometheus-SD
  need, all `get/list/watch`. The collector observes; it never mutates.
- **`memory_limiter` on both** — sheds load before the container hits its memory
  limit (the module-09 RAM ceiling), rather than getting OOM-killed.
- **`start_at: end` on filelog** — only new lines from boot, so no history replay
  spike; `file_storage` remembers the offset across restarts.
- **Security**: gateway is non-root (uid 10001), all caps dropped,
  `readOnlyRootFilesystem`, seccomp `RuntimeDefault`. The agent must be root to
  read host pod logs but is otherwise identically locked down (read-only mount,
  caps dropped, seccomp).
- **PodSecurity**: the agent's hostPath log mount is forbidden under PSA
  `baseline` (Talos's default for non-system namespaces), so `namespace.yaml`
  labels the observability namespace `privileged` — the standard treatment for
  a log-collector DaemonSet (fluent-bit/vector/promtail need the same). The
  Namespace carries `Prune=false` since observability is shared with the
  Victoria backends.
- **Replaced otel-lgtm**: the apps + the Victoria stack now route all telemetry
  through this collector; the single otel-lgtm pod is gone (#57).
- **We keep the legacy component IDs on purpose.** Upstream is renaming component
  types to snake_case with deprecated aliases: `filelog` → `file_log` and
  `otlphttp` → `otlp_http` (already warning at 0.149.0), plus `kubeletstats` →
  `kubelet_stats`, `spanmetrics` → `span_metrics`, `servicegraph` →
  `service_graph` (new warnings at 0.158.0). The aliases still resolve; the cost
  is five `alias is deprecated` WARN lines at gateway startup and three at agent
  startup, which module 09 attendees will see in `kubectl logs`. Renaming would
  make the config unloadable on 0.149.0, i.e. it would break rollback, so the
  rename waits until the aliases are actually removed.
- **`collector.instance.id` on spanmetrics (new at 0.158.0).** The
  `connector.spanmetrics.includeCollectorInstanceID` gate went beta/on by
  default, so `span.calls` / `span.duration` now carry a per-collector-instance
  UUID label. Metric names, types and units are unchanged, and every consumer in
  this repo aggregates (`sum(…)`, `count({__name__=~…})`), so nothing breaks —
  but a *raw* panel will show one line per gateway restart. `exclude_dimensions:
  [ collector.instance.id ]` under `spanmetrics:` restores the old shape if a lab
  ever needs raw series.

## Re-vendor

Bump the tag, then re-resolve the digest:

```sh
mise x crane@0.21.9 -- crane digest docker.io/otel/opentelemetry-collector-contrib:0.158.0
```

Keep the `image:` in both collector manifests and the entry in
`scripts/images.txt` in lockstep (`check-consistency.sh` enforces it).

The config is hand-written, so validate it against the new binary rather than
hoping. Extract `config.yaml` from each ConfigMap and run the release's own
`otelcol-contrib validate --config=file:<path>`; the gateway config must exit 0,
and the agent config fails only on environment-only points (the `/var/lib/otelcol`
hostPath and the in-cluster ServiceAccount CA for `kubeletstats`) — that failure
must be *byte-identical* to the old version's, otherwise something schema-level
moved. Also diff `otelcol-contrib components` between the two versions: a
component we use disappearing from that list is a hard blocker. 0.149.0 → 0.158.0
passed all of this with no config edit.

**Watch on rollback**, not on upgrade: at 0.156.0 `filelog.protobufCheckpointEncoding`
went beta/on, so the offsets in the `/var/lib/otelcol` hostPath become protobuf.
0.158.0 reads the old JSON fine, but a downgrade below 0.156 on a cluster that
already ran 0.158 needs that directory wiped. Fresh `talosctl cluster create`
clusters are unaffected.
