# Vendored: backstage (CNOE prebuilt)

| | |
|---|---|
| Source | https://github.com/cnoe-io/stacks `ref-implementation/backstage/manifests/install.yaml` (pattern) + https://github.com/cnoe-io/backstage-app (image) |
| Image | `ghcr.io/cnoe-io/backstage-app:9232d633b2698fffa6d0a73b715e06640d170162` — the exact tag the CNOE ref-implementation pins on main (2026-07-13); manifest verified pullable on GHCR. **linux/amd64 only** — Apple Silicon runs it under emulation. |
| File | `backstage.yaml` (heavily adapted — treat as ours, diff against CNOE when re-vendoring) |

## What the file actually contains

`backstage.yaml` is one flat manifest set, in this order — the list is the
rebuild checklist, since the file is ours and there is no pristine render to
diff against:

1. `Namespace backstage` (the catalog Application at sync-wave 3 also sets
   `CreateNamespace=true` + `SkipDryRunOnMissingResource=true`, because the CNPG
   `Cluster` CRD may still be landing).
2. `ServiceAccount backstage`.
3. Two ClusterRoles + their bindings: `backstage-read-all` (`*/*`,
   `get/list/watch` — the Kubernetes plugin, and the deliberate teaching
   contrast with the Console's narrow ClusterRole) and
   `backstage-argo-workflows` (`argoproj.io/workflows`, verb `create` — the
   scaffolder submitting Workflows; both mirror CNOE).
4. Three Secrets: `gitea-credentials`, `argocd-credentials` (both consumed via
   `envFrom`, so the *keys* are the env var names the app-config `${…}`
   references) and `k8s-config`, whose `k8s-config.yaml` is the Kubernetes
   plugin's cluster entry (`https://kubernetes.default.svc.cluster.local`,
   `authProvider: serviceAccount`, `skipTLSVerify: true`,
   `skipMetricsLookup: true` — no metrics-server in this cluster — with the SA
   token and CA read via `$file` from the projected SA volume).
5. `ConfigMap backstage-config` — the whole `app-config.yaml` (see below).
6. The CNPG `Cluster backstage-db`.
7. `Service backstage` — NodePort, 7007 → nodePort 30700, selector `app: backstage`.
8. `Deployment backstage`.

### app-config.yaml keys that are load-bearing

- `app.baseUrl` / `backend.baseUrl` / `backend.cors.origin` are all
  `http://backstage.cloudbox.k8s.test` — the *browser's* view. They must move
  together with `BACKSTAGE_HOST_URL`; a mismatch gives a UI that loads and then
  fails every XHR on CORS.
  They move with the hostname scheme
  (docs/superpowers/plans/2026-08-24-talos-box-substrate.md); the NodePort 30700
  Service stays for the port-URL fallback.
- `backend.listen.port: 7007` — matches the container port, the Service
  `targetPort: http` and the probe.
- `backend.csp.connect-src: ["'self'", 'http:', 'https:']` — the CNOE default;
  without it the plain-HTTP in-cluster integrations are blocked by CSP.
- `backend.database` reads `${POSTGRES_HOST|PORT|USER|PASSWORD}` from the
  Deployment env; `backend.cache.store: memory` (no Redis in this cluster).
- `auth.environment: local` + `providers.guest.dangerouslyAllowOutsideDevelopment: true`
  — the image runs `NODE_ENV=production`, so guest auth must opt in explicitly
  or sign-in is impossible. `auth.session.secret` is a static workshop-grade
  string (a lab sandbox; rotating it only logs everyone out).
- `techdocs` is all-`local` (builder, `generator.runIn: local`, publisher) —
  no S3, no Docker generator: the offline rule.
- `scaffolder.defaultAuthor` (`backstage-scaffolder`
  <scaffolder@cloudbox.local>) and `scaffolder.defaultCommitMessage` — Gitea
  rejects a commit with no author, and the lab has no per-attendee identity.
- `catalog.import.entityFilename: catalog-info.yaml` and
  `catalog.import.pullRequestBranchName: backstage-integration` — the file and
  branch the "register existing component" flow writes in Gitea.
- `catalog.rules.allow` lists the entity kinds the workshop uses and
  `catalog.locations: []` is **deliberately empty**, with a commented example
  showing the Gitea `raw/branch/main/catalog-info.yaml` URL — module S3 is the
  attendee editing this key and pushing. Keep the comment when re-vendoring.
- `kubernetes.serviceLocatorMethod: multiTenant` +
  `clusterLocatorMethods: [$include: k8s-config.yaml]` — the `$include` only
  resolves because of the projected volume below. Inside `k8s-config.yaml` the
  cluster entry authenticates with `authProvider: serviceAccount`, reading
  `serviceAccountToken` and `caData` via `$file:` from the pod's own projected
  ServiceAccount token — no credential is committed.
- `argocd.appLocatorMethods` (one `type: config` instance, `in-cluster`, plain
  HTTP) and `integrations.gitea.*` carry the in-cluster URLs and `${…}` refs to
  the two credential Secrets.

### Deployment details that are easy to lose

- **`command: [node, packages/backend, --config, config/app-config.yaml]`** —
  the image's entrypoint would use its own baked config; this points it at ours.
- **The config volume is a `projected` volume**, merging the ConfigMap's
  `app-config.yaml` and the Secret's `k8s-config.yaml` into a single
  `/app/config` mount. Two separate mounts would collide on the same directory
  and break the `$include`.
- **`LOG_LEVEL=info`**, `NODE_TLS_REJECT_UNAUTHORIZED=0` (kept from CNOE, no
  longer load-bearing), `POSTGRES_HOST=backstage-db-rw.backstage.svc.cluster.local`,
  `POSTGRES_PORT=5432`, and `POSTGRES_USER`/`POSTGRES_PASSWORD` via
  `secretKeyRef` on the CNPG-generated `backstage-db-superuser`.
- **A TCP readiness probe on 7007, not HTTP, with a deliberately generous
  window** (`initialDelaySeconds: 30`, `periodSeconds: 10`,
  `failureThreshold: 30` ≈ 5 minutes). The modern backend serves health at
  `/.backstage/health/v1/*` (older ones at `/healthcheck`), so a port check
  survives either; CNOE ships no probe at all. The window exists because first
  boot runs DB migrations *and*, on Apple Silicon, does it under amd64
  emulation — tighten it and the pod restart-loops on exactly the laptops that
  are slowest.
- **Resources: requests 250m/1Gi, limit 2Gi.** The largest single tenant in the
  cluster and a real factor in the module-09 RAM ceiling — this is why Backstage
  is a stretch capability, not a default.

## What was changed vs the CNOE reference

- **Keycloak & external-secrets removed.** Auth = Backstage guest provider
  (`auth.environment: local` + `dangerouslyAllowOutsideDevelopment: true`).
  Verified against the pinned commit: the backend adds
  `plugin-auth-backend-module-guest-provider` unconditionally and the
  frontend renders guest sign-in when `auth.environment == 'local'`.
- **Postgres StatefulSet replaced by a CloudNativePG `Cluster`**
  (`backstage-db`, 1 instance, `storage.size: 2Gi` with an explicit
  `storageClass: local-path`, requests 100m/256Mi and a 512Mi limit,
  `enableSuperuserAccess: true` because Backstage CREATEs one database per
  plugin — and it is the *superuser* secret, `backstage-db-superuser`, the
  Deployment reads, not the usual `-app` one). Postgres image pinned to the
  cnpg-operator 1.28.4 default
  (`ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie`). DB env comes from
  the CNPG-generated `backstage-db-superuser` secret.
- **Integrations point at the in-cluster services**: Gitea
  `http://gitea-http.gitea.svc.cluster.local:3000`, ArgoCD
  `http://argocd-server.argocd.svc.cluster.local` — plain HTTP because the
  bootstrap runs argocd-server with `server.insecure=true` (no TLS behind
  the Service). `NODE_TLS_REJECT_UNAUTHORIZED=0` is kept from CNOE but is
  no longer load-bearing.
- **Service is NodePort 30700**; app/backend baseUrl `http://backstage.cloudbox.k8s.test`.
- Workshop-grade credential Secrets `gitea-credentials` /
  `argocd-credentials` are committed in-line — they MUST match what the
  cluster bootstrap seeds. Gitea admin **`gitea_admin`/`cloudbox123`**
  (`GITEA_ADMIN_USER` / `GITEA_ADMIN_PASSWORD` in `scripts/versions.env` —
  note it is `gitea_admin`, *not* `cloudbox`, which is the S3 user), and the
  ArgoCD read-only local account `backstage`/`cloudbox123`, which
  `scripts/bootstrap-gitops.sh` really does create (`accounts.backstage:
  apiKey, login`, `g, backstage, role:readonly`, and a bcrypt hash of the
  password patched into `argocd-secret`). Changing the password here means
  regenerating that hash there. Coordination point with scripts/.

## Known-untested (flagged)

This exact combination (CNOE image + guest auth + CNPG DB + our app-config)
compiles from verified parts but has NOT been run end-to-end — rehearse in
Phase 1 and expect app-config iteration (e.g. plugins that want more config).
