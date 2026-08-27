# Vendored: platform-api (first-party)

| | |
|---|---|
| Source | **This repo** — `lab/04-self-service/platform/`. Nothing vendored from upstream: the XRD and Composition are the platform API the attendee authors, and this directory is the canonical copy. |
| Images | None. The Composition emits a CNPG `Cluster` (operator-supplied image) and a bucket `Job` running the pinned `s5cmd` image already on `scripts/images.txt`. |
| Files | `xrd.yaml` (the API's schema) · `composition.yaml` (how it is fulfilled) |

## Re-vendor

Nothing to re-vendor. It changes when module 04 changes; `check-consistency.sh`
compares it against `solutions/module-04/`, and `lab/04-self-service/verify.sh`
proves the XRD reaches `ESTABLISHED` on a live cluster.

## Knobs

| Knob | What it is for |
|---|---|
| `256Mi` / `512Mi` *(patched from `spec.size`)* and `100m` | The composed CNPG cluster's memory request/limit and CPU request. They are written as literals in the base resource and then **patched from the T-shirt `size`** (small 256Mi/512Mi, medium 512Mi/1Gi) — the base value is what a `small` gets, so the manifest reads correctly even before the patch runs. |
| `instances` *(patched from `spec.size`)* | Where `size` teaches HA rather than just resources: `large` composes replicas, which is why the XRD's enum is not just a resource dial. |
| `docker.io/peakcom/s5cmd:v2.3.0` | The bucket `Job`'s image: one 12 MiB Go binary that speaks plain S3. It replaced the 129 MiB `aws-cli` image (docs/HAZARDS.md, 2026-08-17) and reads the same `AWS_*` variables any S3 client does. Pinned and on `scripts/images.txt`. |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `BUCKET` | The Job's environment: RustFS credentials plus the bucket name derived from the XR. Workshop-grade values on purpose — the point is that "S3" is an API and an endpoint, not a vendor. The Job is idempotent: `s5cmd ls s3://$BUCKET` is its head-bucket check, so a re-sync does not fail on an existing bucket. |
| readiness `MatchCondition` / `True` / `Complete` | The Composition's readiness rule for the Job: the composed resource counts as ready when its `Complete` condition is `True`. Without it Crossplane treats a finished Job as perpetually not-ready and the XR never goes `Ready`, which looks exactly like a broken composition to an attendee. |

## Design decisions recorded here

- **Crossplane v2, and it matters in every line.** `apiextensions.crossplane.io/v2`
  with `scope: Namespaced` and **no claim names**: v2 XRs are created directly in
  a namespace and Claims are gone. Anything describing `kind: Claim`, `claimNames`
  or a top-level `resources:` list in a Composition is v1 — including most
  tutorials, and most of what an AI assistant will confidently produce. Module 04
  has a slide about exactly this trap.
- **`kind: WorkshopDatabase`, group `platform.cloudbox.io`, `v1alpha1`, short name
  `wdb`.** The group is deliberately *ours*, not `database.example.org`: the
  teaching point is that the platform team owns the API surface. The Console's
  Databases page creates this same kind — module 08's form is ~20 lines because
  this XRD already did the hard part.
- **The API asks for intent, not implementation.** `size` is a T-shirt enum, not
  twelve CNPG fields — the low-cognitive-load attribute from the CNCF platform
  canon, made concrete.
- **The Composition is pipeline-mode and emits plain Kubernetes resources
  directly** — a CNPG `Cluster` plus a `Job` that creates the matching bucket —
  with no `provider-kubernetes` wrapping. That is the v2 capability that makes
  this teachable inside one module: one request in, a whole wired stack out.
- **Crossplane needs an aggregated ClusterRole per composed API group.** It
  composes third-party resources directly, so the grants for
  `postgresql.cnpg.io` and `batch` ship with the crossplane catalog app; without
  them the XR stays `Ready: False` with an RBAC error and nothing else explains
  why.

## Curation block

`scripts/check-vendor-drift.sh` requires every load-bearing knob in `xrd.yaml` /
`composition.yaml` to be mentioned above. Two extracted tokens are the same two
knobs seen twice: the extractor strips whitespace from a value *and its trailing
YAML comment*, so `memory: 256Mi # patched from spec.size` reaches it as one
token. The quantities themselves are documented in the knob table.

```curation
ignore 256Mi#patchedfromspec.size  extractor artifact: the quantity 256Mi glued to its own inline YAML comment; the knob is documented as 256Mi above
ignore 512Mi#patchedfromspec.size  extractor artifact: the quantity 512Mi glued to its own inline YAML comment; the knob is documented as 512Mi above
```
