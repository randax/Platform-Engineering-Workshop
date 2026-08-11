# Vendored: NATS + JetStream

| | |
|---|---|
| Component | NATS server 2.14.4 with JetStream (durable messaging, [PRD-0001](../../../docs/prd/0001-durable-messaging-nats.md)) |
| Image | `nats:2.14.4-alpine` — `sha256:f2123f533c2b0cada0a5c5ec434fb2b8cfe1cf220215ef9d7517e1372917ad66` (crane, 2026-08-11; linux/amd64 + arm64) |
| Sidecar image | `docker.io/natsio/prometheus-nats-exporter:0.20.1` — `sha256:4fbf6dacb84780a45a1c3af9b1080c69451a288d20902deae671b80717bb8f61` (crane, 2026-08-11; linux/amd64 + arm64) |
| Source | Official NATS image, https://hub.docker.com/_/nats · docs https://docs.nats.io |
| Files | `nats.yaml` (ConfigMap + PVC + Service + Deployment), `service-nodeport.yaml` |

## Why not the Helm chart

The official `nats` Helm chart renders a clustered StatefulSet with a config-reloader
sidecar, headless services, and a PodDisruptionBudget — all overkill for a single-node
workshop broker. We hand-write the minimal equivalent (one Deployment, one PVC, plain
config) so attendees can read the whole thing, matching the rustfs treatment.

## Config & curation

- **JetStream on a PVC** (`local-path`, 1 Gi): the store must survive a pod restart or
  the headline demo — kill the pod, watch the durable stream replay — wouldn't work.
  Store caps are deliberately small (64 MiB memory / 512 MiB file): a sandbox, not prod.
- **Deployment strategy `Recreate`**: the JetStream PVC is ReadWriteOnce, so a rolling
  update (two pods briefly) would deadlock on the volume.
- **PVC `Prune=false`**: disabling the app (git rm + push) must not wipe streams
  mid-workshop — same protection as `rustfs-data`.
- **Security**: runs non-root (uid 1000), all caps dropped, `readOnlyRootFilesystem`
  (JetStream only writes the mounted `/data`), `seccompProfile: RuntimeDefault` — passes
  PodSecurity `restricted`.
- **`fsGroup: 1000`, and deliberately no chown initContainer**: kubelet chowns the PVC
  to the nats gid on mount, so JetStream can create its store under `/data` directly.
  Same trick as victoria-metrics.
- **Two probes, two different meanings**: liveness is plain `GET :8222/healthz`;
  readiness is `GET :8222/healthz?js-enabled-only=true`, so "Ready" proves JetStream
  is actually up rather than just the process being alive.
- **Resources**: nats 50m/96Mi → 256Mi limit; exporter 10m/24Mi → 64Mi limit
  (measured idle at 3.9 MiB and 2.9 MiB respectively on 2.14.4/0.20.1).

### The prometheus-nats-exporter sidecar

The component ships **two** containers, not one — this half used to be undocumented
and is the entire data source for the Console's Streams Monitoring panel (#56).

- NATS core speaks only JSON on `:8222`, so the sidecar polls `/varz`, `/connz` and
  `/jsz` over localhost and re-exposes them as Prometheus metrics on `:7777`:
  `args: [ -varz, -connz, -jsz=all, -port, 7777, http://localhost:8222 ]`.
- The pod carries `prometheus.io/scrape: "true"` + `prometheus.io/port: "7777"` — the
  opt-in to the OTel collector gateway's `kubernetes-pods` scrape job. The annotation
  points at **7777, not 8222**: scraping NATS directly would get JSON, not metrics.
- Three names are load-bearing (`apps/portal/internal/metrics/prom.go`, and asserted by
  `.github/workflows/bootstrap-test.yaml`): `gnatsd_varz_connections`,
  `jetstream_server_total_messages`, `jetstream_server_total_message_bytes`. Diff the
  exported name set against the old version on every bump; 0.17.3 → 0.20.1 was
  additions only, and all three are byte-identical in name, labels and value.
- Known upstream break we are **not** exposed to: exporter 0.18.0 added an
  `account_name` label to every `jetstream_stream_*` / `jetstream_consumer_*` series.
  We query none of those families and no dashboard references them, but in a TSDB that
  is a new series identity.

## Re-vendor

```sh
mise x crane@0.21.9 -- crane digest docker.io/library/nats:2.14.4-alpine
mise x crane@0.21.9 -- crane digest docker.io/natsio/prometheus-nats-exporter:0.20.1
```

Hand-written, so verify by running it: boot the new image with the ConfigMap's literal
`nats.conf` under the pod's constraints (`--user 1000:1000 --read-only --cap-drop ALL`),
diff `nats-server --help` against the old version, and check `/varz` reports the store
caps we set. Then **round-trip the store**: create a stream on the old version, restart
onto the new one on the same volume, confirm `Restored N messages` — the catch-up path
reuses the `nats-jetstream` PVC. 2.12.12 → 2.14.4 passed all of this in both directions
(upstream **skipped the 2.13 line entirely**, so this is one minor, not two).

Watch on 2.14: filestore I/O errors now freeze the stream and surface in `/healthz`,
which our *liveness* probe reads — a full PVC that 2.12 tolerated silently now
restarts the container. Better failure mode, new failure mode.

## Workshop addition (not upstream)

`service-nodeport.yaml` exposes the client port at `nats://localhost:30422` so the
`nats` CLI and laptop-side apps connect without a port-forward. Monitoring is on `:8222`
(`/healthz`, `/jsz`, `/varz`) inside the cluster.
