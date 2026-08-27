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
   a `http://<name>-<namespace>.kn.cloudbox.k8s.test` URL via Kourier — no
   separate ingress component. `spec.image` → the container; `spec.replicas`
   `{min,max}` → the `autoscaling.knative.dev/minScale` and
   `autoscaling.knative.dev/maxScale` annotations. **`spec.env` is
   accepted by the XRD but NOT wired in v1** — see the limitations below.
2. **database** — a `WorkshopDatabase` XR (module 04, verbatim), which in turn
   composes a CNPG `Cluster` + a bucket Job. This is the make-or-break
   **composition-of-compositions**.
3. **bucket** — the app's own S3 bucket `<name>-data`, via the module 03/04
   idempotent s5cmd Job (Job named `<name>-storage`).

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

## The details a rewrite must reproduce

These files are ours, so there is no upstream render to diff against — this is
the list that keeps them rebuildable.

**`xrd.yaml`** — `apiextensions.crossplane.io/v2`, `scope: Namespaced`, no
claims. Group `platform.cloudbox.io`, kind `Application`, plural
`applications`, **shortName `app`** (`kubectl get app` is what the lab types).
Version `v1alpha1`, `served` + `referenceable`. `spec.image` is the only
required field; `spec.replicas` defaults to `{}` with `min: 0` / `max: 3` so the
object validates when omitted; `spec.database` / `spec.bucket` default `true`
(and are inert — see limitations); `spec.env` is a `[{name,value}]` array (also
inert). `metadata.properties.name.maxLength: 40` — deliberate and load-bearing:
the composed ksvc's host is `<name>-<namespace>` in ONE DNS label, so the name
has to leave room for the namespace. Crossplane honours it (`genCrdVersion`
takes the smaller of its own default and ours,
crossplane `internal/xcrd/crd.go`) rather than dropping the block. Keep it in
step with `dnsName` in `apps/portal/internal/kube/resources.go`; the pair check
that a schema cannot express lives there too (`ValidKnativeHost`). See
`docs/HAZARDS.md`, "the dash that made routing work".

**`composition.yaml`** — `mode: Pipeline`, one step against
`function-patch-and-transform` (the name must match the installed Function,
shared with module 04), three resources:

- **workload base defaults mirror the XRD defaults** — `minScale: "0"`,
  `maxScale: "3"`. If the two ever disagree, an XR that omits `spec.replicas`
  gets whichever the base carries.
- **The base image is a real, pre-pulled ref**
  (`ghcr.io/randax/cloudbox-uploader`, tag below) inside
  `x-release-please-start/end-version` block comments, not a placeholder. It exists so the manifest is valid
  standalone and so `check-consistency.sh`'s "every image is pre-pulled" check
  passes; release-please rewrites the tag. Never replace it with something like
  `example/app:latest`.
- **The workload's S3 env is platform-injected**: `S3_ENDPOINT` →
  `http://rustfs-svc.rustfs.svc.cluster.local:9000`, workshop creds
  `cloudbox`/`cloudbox123` (must match the rustfs component), and `S3_BUCKET`
  patched to `<name>-data`.
- **Patches address env by index** — `env[0]` is `DATABASE_URL` (its
  `secretKeyRef.name` patched to `<name>-pg-app`) and `env[4]` is `S3_BUCKET`.
  Reorder the base env array and the patches silently write to the wrong
  variable; the same applies to the bucket Job's `env[3]` (`BUCKET`).
- **Numeric → annotation needs `convert: int64` before `Format: "%d"`.** The
  replicas arrive as JSON numbers (float64); formatting them directly yields
  `"0.000000"` in an annotation Knative then rejects. Module 04 hit the same
  gotcha with `storageGB`.
- **The `database` resource sets `spec.size: small`** (the WorkshopDatabase
  T-shirt knob, PRD-0006) and patches **both `metadata.name` and
  `metadata.namespace`** — the namespace patch is what keeps a namespaced XR
  from landing in the wrong place.
- **Every resource carries a `readinessCheck`**: `MatchCondition Ready=True` on
  the workload and the database, `MatchCondition Complete=True` on the Job.
  These are what make the Application's own readiness mean something — without
  them the XR reports Ready while its database is still provisioning.
- **The bucket Job** is `backoffLimit: 6`, `restartPolicy: OnFailure`, the
  pinned `docker.io/peakcom/s5cmd:v2.3.0` image, `ls || mb`
  for idempotency, and `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
  `AWS_REGION=eu-north-1` (the client refuses to sign SigV4 without a region) —
  the same workshop-grade `cloudbox`/`cloudbox123` credentials the workload gets
  as `S3_ACCESS_KEY` / `S3_SECRET_KEY`. s5cmd **replaced
  `public.ecr.aws/aws-cli/aws-cli:2.36.24` on 2026-08-17** (docs/HAZARDS.md):
  identical env-var and `--endpoint-url` plumbing, 12 MiB against 129 MiB, and
  it does not put an AWS-branded CLI in a workshop about not using AWS. Two
  details a re-vendor must keep: `ENTRYPOINT` is `/s5cmd`, so `command:
  ["/bin/sh","-c"]` is what provides the shell the guard needs (busybox is
  present — the image is alpine-minirootfs 3.20.3) and the binary is invoked by
  absolute path; and `s5cmd ls s3://<bucket>` is the `head-bucket` stand-in,
  exit 0 when the bucket exists even if empty, exit 1 + `NoSuchBucket` when it
  does not. Keep the guard: `restartPolicy: OnFailure` would hot-loop on a
  non-zero exit, and while `mb` on an existing bucket does exit 0 against RustFS
  1.0.0-rc.2 (measured 2026-08-17), that is the store's `CreateBucket`
  behaviour rather than a promise from s5cmd.
- **Every composed container asks for 50m/64Mi** and limits memory at 256Mi —
  the small-cluster convention used by every other component here. Job name `<name>-storage`, bucket `<name>-data` — deliberately
  distinct from the WorkshopDatabase's own `<name>-bucket`/`<name>-assets` so
  the two Jobs can coexist in one namespace.

**`rbac.yaml`** — a ClusterRole labelled
`rbac.crossplane.io/aggregate-to-crossplane: "true"` (that label is the entire
mechanism; without it the rules are inert) granting full lifecycle over
`serving.knative.dev/services` and `platform.cloudbox.io/*`. Crossplane only
gets RBAC over its own types, so a composition that emits a third-party kind
fails with a plain "forbidden" until its group is aggregated in.

## v1 limitations (deferred to follow-ups — call these out in review)

- **`spec.env` is inert.** The XRD accepts it (and its description says
  "appended to the platform-injected ones"), but the composition emits **no
  patch for it** — `function-patch-and-transform`'s `PatchPolicy` has no
  `mergeOptions.appendSlice` (that was classic-Composition syntax), and the
  modern array-append form needs a cluster to verify. So a developer can set
  `spec.env` and nothing happens, silently. v1 ships the platform-injected
  DB/S3 env only. Fix the XRD description or land the patch — do not "fix" this
  by trusting the description.
- **`database` / `bucket` are NOT gated.** `function-patch-and-transform` has no
  per-resource conditional, so both resources are **always** emitted regardless
  of the boolean. The flags are kept in the API for forward-compat; honoring
  `false` needs `function-go-templating` or `function-cel-filter` (a new Function
  to install + mirror). Because the DB is always created, `DATABASE_URL` always
  resolves — the composition is internally consistent as-is.
- **NATS queue (`spec.queue`) and explicit `spec.ingress` host** from the PRD are
  **out of scope for v1** (queue depends on PRD-0001; the Knative URL already
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
7. **The `metadata.name` maxLength survives into the CRD.** Read against
   crossplane's source, not a cluster: `kubectl get crd
   applications.platform.cloudbox.io -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.metadata.properties.name.maxLength}'`
   should print `40`, and a 41-character name should be refused by the API
   server. If a future Crossplane drops the block instead, the Console still
   enforces it — but `kubectl apply` would stop agreeing with the Console.

## Prerequisites

- `crossplane` (wave 2) + its `function-patch-and-transform` Function.
- `platform-api` (wave 5, module 04) — installs the `WorkshopDatabase` XRD this
  composition composes. **Without it, the `database` resource cannot be created.**
- `cnpg-operator`, `rustfs`, `knative-serving` (Kourier).

## Deployed image tags

The composition's workload base and the bucket Job pin these refs; the block is
an `extra-files` entry in `release-please-config.json`, so release-please keeps
it in step with `composition.yaml` instead of letting this file rot behind it.

<!-- x-release-please-start-version -->
```
ghcr.io/randax/cloudbox-uploader:v0.3.0
```
<!-- x-release-please-end-version -->
