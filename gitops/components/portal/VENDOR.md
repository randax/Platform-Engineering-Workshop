# Vendored: portal (Cloudbox Console — first-party)

| | |
|---|---|
| Source | `apps/portal` **in this repo** — nothing vendored from upstream; the manifest is ours |
| Image | `ghcr.io/randax/cloudbox-portal:v0.1.0` (multi-arch) — **PENDING**: built and pushed by this repo's CI from `apps/portal`; not yet on GHCR as of 2026-07-14. Verify with `crane manifest` once CI has run, then add to `scripts/images.txt`. |
| File | `portal.yaml` |

## Re-vendor

Nothing to re-vendor. To ship a new portal version: bump the tag in
`apps/portal` CI, wait for the GHCR push, update the image tag in
`portal.yaml` and in `scripts/images.txt`, push.

## Design decisions recorded here

- **RBAC is least-privilege by design** (teaching contrast with the
  Backstage demo's read-all ClusterRole): a ClusterRole reading only
  `applications.argoproj.io`, `clusters.postgresql.cnpg.io`,
  `services.serving.knative.dev`, `pods`, `namespaces`; plus a
  namespaced Role in `demo` granting create/get/list/delete on
  `workshopdatabases.platform.cloudbox.io` (the Crossplane v2 namespaced
  XR from `lab/04-self-service/platform/xrd.yaml`).
- **The Role lives in the `demo` namespace**, which this component does
  NOT create (module 04's demo component owns it). Enabling portal before
  module 04 leaves the Application retrying/degraded until `demo` exists —
  acceptable in module order, documented in the catalog header.
- **`UPLOADER_URL=http://uploader.pipeline.svc.cluster.local`** — the
  cluster-local domain of the `uploader` Knative Service
  (`networking.knative.dev/visibility: cluster-local` gives a ksvc the URL
  `http://<name>.<namespace>.svc.cluster.local`, routed via
  kourier-internal; port 80 implied).
- **Service NodePort 30600** (`http://localhost:30600`), container port
  8080, `/healthz` readiness+liveness — port and health path are the
  contract with `apps/portal` (Knative-style `$PORT=8080` default).
- S3 credentials `cloudbox`/`cloudbox123` are workshop-grade on purpose
  (ephemeral lab sandbox) and must match the rustfs component. The
  `images` bucket is created by picture-pipeline's setup Job.
- Requests 50m/64Mi, limit 128Mi — small Go binary, small cluster.
