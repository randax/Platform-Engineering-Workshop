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

Both export over plain HTTP through three separately-named exporters —
`otlphttp/traces`, `otlphttp/metrics` and `otlphttp/logs`, one per Victoria
backend, because each needs its own explicit full `*_endpoint` path — to
`victoria-metrics:8428/opentelemetry/v1/metrics` and
`victoria-logs:9428/insert/opentelemetry/v1/logs`. `VL-Stream-Fields` tells
VictoriaLogs which resource attributes partition the streams (its Loki-label
equivalent).

## Curation

- **`filelog.exclude` skips the agent's own pod logs**
  (`/var/log/pods/observability_otel-collector-agent*/*/*.log`). Without it the
  agent tails its own stdout, every log line produces at least one more, and a
  single warning turns into a self-feeding loop that fills VictoriaLogs on a
  laptop-sized cluster. Non-obvious and easy to drop on a re-vendor.
- **`batch` (timeout 10s) after `memory_limiter` in every pipeline** — one
  export per 10s instead of per record; the ordering matters (limit first, then
  batch).
- **The `memory_limiter` numbers are tied to the container limits**: agent
  `limit_mib: 200` / `spike_limit_mib: 50` under a 256Mi limit, gateway
  `limit_mib: 400` / `spike_limit_mib: 100` under 512Mi (~80% each). Explicit
  MiB, not a percentage, so behaviour is the same across attendee cgroup
  setups. **Change one and change the other** — a limiter above the container
  limit is worse than none, because the pod OOMKills before it ever sheds.
- **Resources** (module-09 RAM ceiling): agent requests 50m/128Mi, limit 256Mi;
  gateway requests 100m/128Mi, limit 512Mi.
- **`health_check` extension on :13133 + probes.** Both collectors expose it and
  both use `httpGet /` on 13133 for liveness (15s/10s) and readiness (5s/5s).
  The port is deliberately **not** on the Service — it is a probe surface, not
  an API.
- **The agent tolerates everything** (`tolerations: [{operator: Exists}]`) so
  the DaemonSet also runs on the control-plane node. Drop it and the CP node's
  pod logs and node metrics silently vanish — half the cluster on a 1 CP + 1
  worker `talosctl cluster create`.
- **`K8S_NODE_IP` via the downward API** (`fieldRef: status.hostIP`) — the
  agent's `kubeletstats` endpoint is `https://${env:K8S_NODE_IP}:10250`, so the
  env var is load-bearing config, not decoration.
- **`checksum/config` pod annotation** (`"stage2-v1"` agent, `"stage2-v3"`
  gateway) is **hand-maintained**: editing a ConfigMap does not restart a
  DaemonSet or Deployment. Bump the string whenever you touch that collector's
  `config.yaml`, or the change only lands on the next unrelated pod restart —
  the classic "I fixed the config and nothing changed" hour.
- **Gateway `strategy: Recreate`, `replicas: 1`** — `k8s_cluster` and the
  prometheus scrape jobs must run exactly once, and a rolling update would
  briefly double-count.
- **`app.kubernetes.io/version: "0.158.0"`** on both workloads is hand-kept —
  bump it with the image tag/digest.
- **The two `VL-Stream-Fields` headers differ on purpose**: the agent partitions
  by `k8s.namespace.name,k8s.pod.name,k8s.container.name` (pod logs), the
  gateway by `service.name,k8s.namespace.name` (app OTLP logs). Copying one
  over the other gives VictoriaLogs a stream key that doesn't exist on that
  signal.
- **Connector shapes are load-bearing for module 09**: `spanmetrics` uses
  `namespace: span` (hence `span_calls_total` / `span_duration_*`, never
  colliding with app metric names) with explicit 5ms…5s buckets;
  `servicegraph` uses 10ms…5s buckets and `store.ttl: 30s` / `max_items: 2000`.
  **The 30s TTL is the curation**: the broker → resizer edge crosses a Knative
  scale-from-zero cold start, so a shorter store drops the client/server pair
  and that hop disappears from the service map.
- **The gateway Service publishes only OTLP** — `otel-collector` (ClusterIP)
  with 4317 (grpc) + 4318 (http). That name/port pair is the endpoint the
  first-party apps are configured against.
- **RBAC is read-only** — one ServiceAccount shared by both collectors; the
  ClusterRole is the union of what k8s_cluster / kubeletstats / prometheus-SD
  need, all `get/list/watch`. The collector observes; it never mutates. The
  grant, written out because widening it is a privilege decision — core:
  `events`, `namespaces`, `namespaces/status`, `nodes`, `nodes/spec`,
  `nodes/stats`, `nodes/proxy`, `pods`, `pods/status`,
  `replicationcontrollers`, `replicationcontrollers/status`, `resourcequotas`,
  `services`, `endpoints`; apps: `daemonsets`, `deployments`, `replicasets`,
  `statefulsets`; batch: `jobs`, `cronjobs`; autoscaling:
  `horizontalpodautoscalers`.
- **`checksum/config` pod annotations** (`stage2-v1` on the agent,
  `stage2-v3` on the gateway) — bumped by hand whenever the collector config
  changes, so ArgoCD's sync actually restarts the pods instead of leaving them
  on the old config (a plain ConfigMap edit does not roll a Deployment).
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
  labels the observability namespace `privileged` on all three PSA modes —
  `pod-security.kubernetes.io/enforce`, `pod-security.kubernetes.io/audit` and
  `pod-security.kubernetes.io/warn` — the standard treatment for a
  log-collector DaemonSet (fluent-bit/vector/promtail need the same); labelling
  only `enforce` would leave the audit log and `kubectl` full of warnings about
  a pod we deliberately allow. The Namespace carries
  `argocd.argoproj.io/sync-options: Prune=false` since observability is shared
  with the Victoria backends.
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
