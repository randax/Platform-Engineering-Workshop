# Vendored: portal (Cloudbox Console — first-party)

| | |
|---|---|
| Source | `apps/portal` **in this repo** — nothing vendored from upstream; the manifest is ours |
| Image | `ghcr.io/randax/cloudbox-portal` (multi-arch) — built and pushed by this repo's CI from `apps/portal`; published and public on GHCR, anonymous `crane` pull verified 2026-08-10. In `scripts/images.txt`. The deployed tag is below. |

<!-- x-release-please-start-version -->
```
ghcr.io/randax/cloudbox-portal:v0.4.0
```
<!-- x-release-please-end-version -->

release-please rewrites that block (it is an `extra-files` entry in
`release-please-config.json`), so it cannot fall behind `portal.yaml`.
| File | `portal.yaml` |

## Re-vendor

Nothing to re-vendor, and nothing to bump by hand. Merge a conventional
commit under `apps/portal`; release-please's release PR bumps the tag in
`portal.yaml`, in `scripts/images.txt` and everywhere else it is pinned,
and merging it publishes the images. See `apps/README.md` → "Releasing the
images". The tag in the table above is the exception: a markdown table row
cannot carry the block annotations, so this file is not a release-please
extra-file — its version is prose, kept honest by review.

## Design decisions recorded here

- **This component ships its own `Namespace portal`** plus the ServiceAccount,
  ClusterRole, ClusterRoleBinding, Deployment and Service — everything the
  console needs except the `demo` Role below. (The catalog Application also
  sets `CreateNamespace=true`, a harmless overlap.)
- **RBAC is least-privilege by design** (teaching contrast with the
  Backstage demo's read-all ClusterRole): one ClusterRole `portal-read`,
  `get/list/watch` only, over exactly the surfaces the console renders —
  `applications.argoproj.io` **and `workflows`**, `clusters.postgresql.cnpg.io`,
  `services.serving.knative.dev`, core `pods`/`namespaces`/`nodes`/`events`
  **and `secrets`**, and `apps` `deployments`/`statefulsets`/`daemonsets`. The last three groups
  are easy to miss and each one is a page: `nodes` + `events` back the cluster
  inventory and the event feed, `apps/*` backs the `/components` status page
  and the `/workshop` checklist — drop them and those pages render "forbidden"
  instead of state.
- **`workflows` is read-only here, and that is the whole design.** `get/list/watch`
  on `workflows.argoproj.io` is what the Builds page lists — module 07's runs,
  read back after the fact. The console also *submits* workflows (New Function,
  and "Build from a repo"), and it deliberately cannot do that with this
  ClusterRole: creating one needs `lab/08-portal/portal-functions-access.yaml`, a
  namespaced Role in `builds` the attendee pushes through git. Same lesson as the
  `demo` Role below — read cluster-wide, write only where you were handed a key.
- **`secrets` is the one rule that deserves an argument, and it is `get/list/watch`
  cluster-wide.** It backs the Databases page's query terminal: connecting to a
  composed database means reading CNPG's generated `<cluster>-app` Secret, which
  holds that database's user and password (`internal/web/databases.go`, via
  `GetSecret`). Say plainly what that costs: a read-only account that can read
  every Secret in the cluster is, in a real platform, a credential-exfiltration
  path — the honest fix is a namespaced Role beside `portal-access.yaml`, or a
  `resourceNames` restriction to `*-app`, and neither is in place. It is scoped
  the way it is because the console must reach any project namespace an attendee
  creates during the lab, and it is defensible only because this cluster lives on
  one laptop for four hours. Anyone lifting this manifest into something real
  should tighten it first.
- **This component ships NO resources in the `demo` namespace.** XR
  self-service (the Databases page: create/get/list/delete on
  `workshopdatabases.platform.cloudbox.io`, the Crossplane v2 namespaced XR
  from `lab/04-self-service/platform/xrd.yaml`) requires the module-08 Role —
  `lab/08-portal/portal-access.yaml`, which the attendee copies into
  `gitops/components/demo/` **in their own platform repo** (canonical copy:
  `solutions/module-08/components/demo/portal-access.yaml`). It ships
  alongside the `demo` namespace itself. Shipping that Role from here would
  deadlock a mass sync: portal
  syncs at wave 3, the namespace arrives later, the dry-run fails on the
  missing namespace and the health gate blocks every later wave. Module 08
  teaches pushing the Role as a one-file change; until it lands, the
  Databases page shows a friendly forbidden error.
- **`UPLOADER_URL=http://uploader.pipeline.svc.cluster.local`** — the
  cluster-local domain of the `uploader` Knative Service
  (`networking.knative.dev/visibility: cluster-local` gives a ksvc the URL
  `http://<name>.<namespace>.svc.cluster.local`, routed via
  kourier-internal; port 80 implied).
- **Service NodePort 30600**, published at
  http://portal.cloudbox.k8s.test (ingress.yaml), container port
  8080, `/healthz` readiness+liveness — port and health path are the
  contract with `apps/portal` (Knative-style `$PORT=8080` default).
- **`ingress.cilium.io/request-timeout: "0s"`** on that Ingress = **no**
  timeout. The Console's agent-ask answer is an SSE stream that runs for as
  long as the model takes, and a Cilium Ingress is an Envoy route whose default
  timeout is 15 s — long enough to make module 10 look broken. See
  `docs/HAZARDS.md`, "NodePorts had no proxy in the path".
- **Two S3 endpoints, and they are not interchangeable.**
  `S3_ENDPOINT=http://rustfs-svc.rustfs.svc.cluster.local:9000` is what the
  *pod* talks to; `S3_PUBLIC_ENDPOINT=s3.cloudbox.k8s.test` is the host the
  *browser* must see, because gallery images are served through presigned URLs
  that the browser fetches directly. It must track `RUSTFS_S3_HOST` in
  `scripts/versions.env` — set it to the in-cluster Service and every gallery
  thumbnail 404s in the attendee's browser while working fine from inside the
  cluster.
- **`GRAFANA_URL=http://grafana.cloudbox.k8s.test`** — browser-facing, matches
  `GRAFANA_HOST_URL` and the `grafana` component's Ingress. Source of the
  console's Explore deep-links (which also depend on the datasource uids —
  see `../grafana/VENDOR.md`).
- **`KNATIVE_DOMAIN=kn.cloudbox.k8s.test`** — browser-facing domain for
  composed Application XR workloads; the portal constructs
  `<name>-<namespace>.<domain>` links from it (the dash is Knative's
  `domain-template`; see `ksvcURL` in `apps/portal/internal/web/applications.go`).
- **`GITEA_USER=gitea_admin` / `GITEA_PASSWORD=cloudbox123`** — the scaffold
  bridge (PRD-0012): the console calls Gitea's *generate* API to create a
  tenant repo from a template. Workshop-grade and committed like the S3 creds;
  must match the `gitea_admin` credentials in `scripts/versions.env` /
  `bootstrap-gitops.sh`. Degrades gracefully: with `GITEA_USER` unset the
  "start from a template" option is simply not offered.
- S3 credentials `cloudbox`/`cloudbox123` (`S3_ACCESS_KEY` / `S3_SECRET_KEY`)
  are workshop-grade on purpose
  (ephemeral lab sandbox) and must match the rustfs component. The
  `images` bucket (`S3_BUCKET=images`) is created by picture-pipeline's setup
  Job — until that component is enabled the gallery is empty but the page
  still loads.
- Requests 50m/64Mi, limit 128Mi — small Go binary, small cluster.
