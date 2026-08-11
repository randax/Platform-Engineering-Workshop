# Vendored: picture-pipeline (first-party)

| | |
|---|---|
| Source | `apps/uploader` + `apps/resizer` **in this repo** — nothing vendored from upstream; the manifest is ours |
| Images | `ghcr.io/randax/cloudbox-uploader:v0.1.0`, `ghcr.io/randax/cloudbox-resizer:v0.1.0` (multi-arch) — built and pushed by this repo's CI from `apps/`; published and public on GHCR, anonymous `crane` pull verified 2026-08-10. In `scripts/images.txt`. `public.ecr.aws/aws-cli/aws-cli:2.36.20` (bucket Job) is pinned and verified pullable, amd64+arm64 (crane, 2026-08-11) — already in the pre-pull list for module 03. |
| File | `picture-pipeline.yaml` |

## Re-vendor

Nothing to re-vendor, and no tag to bump by hand: release-please's release PR
rewrites the pinned tags in `picture-pipeline.yaml`, in `scripts/images.txt`
and everywhere else, and merging it publishes the images. See
`apps/README.md` → "Releasing the images". The tags in the table above are
the exception: a markdown table row cannot carry the block annotations, so
this file is not a release-please extra-file — its version is prose, kept
honest by review.

## Design decisions recorded here

- **Broker `default` is in-memory** (`MTChannelBasedBroker` over the
  InMemoryChannel that knative-eventing defaults to). The broker.class
  annotation is redundant with `config-br-defaults` but kept explicit for
  teachability. In-memory means **no durability** — an imc-dispatcher
  restart drops in-flight events. Deliberate: this is a 4-hour lab, not
  Kafka school.
- **Both ksvcs are cluster-local**
  (`networking.knative.dev/visibility: cluster-local` label on the
  Service): their URLs become `http://<name>.pipeline.svc.cluster.local`
  served via kourier-internal (ClusterIP), so nothing leaks out of the
  Kourier NodePort. The portal is the only external surface.
- **`BROKER_URL`** uses the MT broker ingress form:
  `http://broker-ingress.knative-eventing.svc.cluster.local/<namespace>/<broker>`.
- **Trigger `resize-on-upload`** exact-matches CloudEvent attribute
  `type: dev.cloudbox.image.uploaded` → subscriber ksvc `resizer`. The
  event type string is a contract with `apps/uploader`.
- **Job `create-images-bucket`** carries the one thing GitOps can't: the
  S3 bucket. Same pinned `aws-cli` image and idempotent
  `head-bucket || create-bucket` pattern as `solutions/*/post.sh` and the
  platform-api composition. `backoffLimit: 20` rides out RustFS still
  starting; no TTL so the completed Job persists and ArgoCD doesn't
  re-create it every reconcile.
- S3 credentials `cloudbox`/`cloudbox123` are workshop-grade on purpose
  (ephemeral lab sandbox) and must match the rustfs component.
