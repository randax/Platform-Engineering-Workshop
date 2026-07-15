# Vendored: NATS + JetStream

| | |
|---|---|
| Component | NATS server 2.12.12 with JetStream (durable messaging, [PRD-0001](../../../docs/prd/0001-durable-messaging-nats.md)) |
| Image | `nats:2.12.12-alpine` — `sha256:2ca98656a279b2d88cfdf2b8c3f0d5d7f3941ae9dc2ab12ebaa92d83e0f4ccdb` (crane, 2026-07-15) |
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

## Workshop addition (not upstream)

`service-nodeport.yaml` exposes the client port at `nats://localhost:30422` so the
`nats` CLI and laptop-side apps connect without a port-forward. Monitoring is on `:8222`
(`/healthz`, `/jsz`, `/varz`) inside the cluster.
