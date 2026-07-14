# Vendored: backstage (CNOE prebuilt)

| | |
|---|---|
| Source | https://github.com/cnoe-io/stacks `ref-implementation/backstage/manifests/install.yaml` (pattern) + https://github.com/cnoe-io/backstage-app (image) |
| Image | `ghcr.io/cnoe-io/backstage-app:9232d633b2698fffa6d0a73b715e06640d170162` — the exact tag the CNOE ref-implementation pins on main (2026-07-13); manifest verified pullable on GHCR. **linux/amd64 only** — Apple Silicon runs it under emulation. |
| File | `backstage.yaml` (heavily adapted — treat as ours, diff against CNOE when re-vendoring) |

## What was changed vs the CNOE reference

- **Keycloak & external-secrets removed.** Auth = Backstage guest provider
  (`auth.environment: local` + `dangerouslyAllowOutsideDevelopment: true`).
  Verified against the pinned commit: the backend adds
  `plugin-auth-backend-module-guest-provider` unconditionally and the
  frontend renders guest sign-in when `auth.environment == 'local'`.
- **Postgres StatefulSet replaced by a CloudNativePG `Cluster`**
  (`backstage-db`, 1 instance, 2Gi on local-path,
  `enableSuperuserAccess: true` because Backstage CREATEs one database per
  plugin). Postgres image pinned to the cnpg-operator 1.28.4 default
  (`ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie`). DB env comes from
  the CNPG-generated `backstage-db-superuser` secret.
- **Integrations point at the in-cluster services**: Gitea
  `http://gitea-http.gitea.svc.cluster.local:3000`, ArgoCD
  `http://argocd-server.argocd.svc.cluster.local` — plain HTTP because the
  bootstrap runs argocd-server with `server.insecure=true` (no TLS behind
  the Service). `NODE_TLS_REJECT_UNAUTHORIZED=0` is kept from CNOE but is
  no longer load-bearing.
- **Service is NodePort 30700**; app/backend baseUrl `http://localhost:30700`.
- Workshop-grade credential Secrets `gitea-credentials` /
  `argocd-credentials` are committed in-line — they MUST match what the
  cluster bootstrap seeds (Gitea admin `cloudbox`/`cloudbox123`; an ArgoCD
  read-only local account `backstage`). Coordination point with scripts/.

## Known-untested (flagged)

This exact combination (CNOE image + guest auth + CNPG DB + our app-config)
compiles from verified parts but has NOT been run end-to-end — rehearse in
Phase 1 and expect app-config iteration (e.g. plugins that want more config).
