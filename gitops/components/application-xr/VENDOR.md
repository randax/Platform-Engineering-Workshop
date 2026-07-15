# Component: application-xr (golden-path `Application` XR)

The platform's headline self-service abstraction (PRD-0003). One namespaced
`Application` XR → a running, URL-addressable workload with its Postgres +
bucket provisioned and wired in. Built **on top of** module 04's
`WorkshopDatabase` XR (composition-of-compositions), reusing the exact same
Crossplane v2 pipeline + `function-patch-and-transform` — no new components.

| | |
|---|---|
| Kind | `platform.cloudbox.io/v1alpha1`, `Application` (Namespaced, Crossplane v2, no claims) |
| Files | `xrd.yaml` (the API), `composition.yaml` (the implementation), `rbac.yaml` (Crossplane grants) |
| Function | `function-patch-and-transform` (shared with the WorkshopDatabase composition) |
| Delivered by | `gitops/catalog/application-xr.yaml` (ArgoCD Application, sync-wave 6) |
| Example | `lab/04-self-service/examples/my-application.yaml` |

## What one `Application` composes (in the XR's own namespace)

1. **workload** — a Knative `Service` named after the XR. Free scale-to-zero and
   a `http://<name>.<namespace>.127.0.0.1.sslip.io:31080` URL via Kourier — no
   separate ingress component. `spec.image` → the container; `spec.replicas`
   `{min,max}` → `autoscaling.knative.dev/{minScale,maxScale}`; `spec.env` is
   **appended** (patch `mergeOptions.appendSlice`) to the platform-injected env.
2. **database** — a `WorkshopDatabase` XR (module 04, verbatim), which in turn
   composes a CNPG `Cluster` + a bucket Job. This is the make-or-break
   **composition-of-compositions**.
3. **bucket** — the app's own S3 bucket `<name>-data`, via the module 03/04
   idempotent aws-cli Job (Job named `<name>-storage`).

## Secret wiring — how the app boots already connected

The DB connection secret name is **deterministic**, so `function-patch-and-transform`
can construct it (no read-back of a runtime-generated value needed):

```
Application "my-app"
  → WorkshopDatabase "my-app"
    → CNPG Cluster "my-app-pg"          (WorkshopDatabase names it "<name>-pg")
      → CNPG app secret "my-app-pg-app" (CNPG convention "<cluster>-app")
```

So the workload's `DATABASE_URL` is wired via `secretKeyRef{ name: "<name>-pg-app",
key: "uri" }` with a `Format` patch. Because a Knative revision with a
`secretKeyRef` to a not-yet-existent secret won't become Ready, the workload is
**naturally ordered after the database** — no explicit readiness gate needed.

## v1 limitations (deferred to follow-ups — call these out in review)

- **`database` / `bucket` are NOT gated.** `function-patch-and-transform` has no
  per-resource conditional, so both resources are **always** emitted regardless
  of the boolean. The flags are kept in the API for forward-compat; honoring
  `false` needs `function-go-templating` or `function-cel-filter` (a new Function
  to install + mirror). Because the DB is always created, `DATABASE_URL` always
  resolves — the composition is internally consistent as-is.
- **NATS queue (`spec.queue`) and explicit `spec.ingress` host** from the PRD are
  **out of scope for v1** (queue depends on PRD-0001; the sslip.io URL already
  covers ingress for the golden path).
- **Redundant bucket when a DB exists.** The `WorkshopDatabase` also creates a
  bucket (`<name>-assets`, Job `<name>-bucket`). The app's own bucket is
  `<name>-data` (Job `<name>-storage`) — distinct names, no collision, but two
  buckets exist per app in v1. The workload uses `<name>-data`.

## NEEDS A CLUSTER REHEARSAL (not validated — no live cluster here)

Everything below is static-checked (kubeconform + consistency) but **not** proven
to compose. Rehearse before calling it done:

1. **Composition-of-compositions readiness.** Confirm the `Application` XR only
   goes `Ready` after the nested `WorkshopDatabase` (and its CNPG Cluster) is
   Ready — i.e. readiness propagates up two levels. This is PRD-0003's flagged
   make-or-break.
2. **CNPG secret name + key.** The wiring assumes CNPG creates `<name>-pg-app`
   with a `uri` key holding a usable DSN. Verify both the secret name and that
   `uri` (vs `jdbc-uri`/`username`+`password`) is what the app wants.
3. **`mergeOptions.appendSlice` on env.** Confirm `spec.env` is appended after
   the injected env (indices preserved) rather than replacing the array.
4. **RBAC.** Confirm Crossplane can create `serving.knative.dev/Service` and the
   `WorkshopDatabase` XR (rbac.yaml here + the rbac-manager's auto-generated XR
   roles).
5. **Knative + secretKeyRef start ordering.** Confirm the revision tolerates the
   secret being absent initially and recovers once CNPG writes it (no permanent
   `CreateContainerConfigError`).
6. **Namespace propagation.** Confirm the composed `WorkshopDatabase` lands in
   the Application's namespace (patched `metadata.namespace`).

## Prerequisites

- `crossplane` (wave 2) + its `function-patch-and-transform` Function.
- `platform-api` (wave 5, module 04) — installs the `WorkshopDatabase` XRD this
  composition composes. **Without it, the `database` resource cannot be created.**
- `cnpg-operator`, `rustfs`, `knative-serving` (Kourier).
