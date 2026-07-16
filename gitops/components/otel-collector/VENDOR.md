# Vendored: OpenTelemetry Collector (contrib)

| | |
|---|---|
| Component | OTel Collector 0.149.0 — the collection layer of the Victoria stack ([issue #57](https://github.com/randax/Platform-Engineering-Workshop/issues/57), Stage 2 — closes the "only 3 apps push anything" gap) |
| Image | `docker.io/otel/opentelemetry-collector-contrib:0.149.0` — `sha256:0fba96233274f6d665ac8831ad99dfe6479a9a20459f6e2719c0d20945773b46` (crane, 2026-07-15; linux/amd64 + arm64) |
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
  - Exports: metrics → VM, logs → VLogs.

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

## Re-vendor

Bump the tag, then re-resolve the digest:

```sh
mise x crane@0.21.7 -- crane digest docker.io/otel/opentelemetry-collector-contrib:0.149.0
```

Keep the `image:` in both collector manifests and the entry in
`scripts/images.txt` in lockstep (`check-consistency.sh` enforces it).
