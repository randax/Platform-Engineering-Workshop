# Vendored: picture-pipeline (first-party)

| | |
|---|---|
| Source | `apps/uploader` + `apps/resizer` **in this repo** — nothing vendored from upstream; the manifest is ours |
| Images | `ghcr.io/randax/cloudbox-uploader`, `ghcr.io/randax/cloudbox-resizer` (multi-arch; deployed tags below) — built and pushed by this repo's CI from `apps/`; published and public on GHCR, anonymous `crane` pull verified 2026-08-10. In `scripts/images.txt`. `public.ecr.aws/aws-cli/aws-cli:2.36.24` (bucket Job) is pinned and verified pullable, amd64+arm64 (crane, 2026-08-17) — already in the pre-pull list for module 03. |
| File | `picture-pipeline.yaml` |

<!-- x-release-please-start-version -->
```
ghcr.io/randax/cloudbox-uploader:v0.2.0
ghcr.io/randax/cloudbox-resizer:v0.2.0
```
<!-- x-release-please-end-version -->

release-please rewrites that block (an `extra-files` entry in
`release-please-config.json`), so it cannot fall behind the manifest.

## Re-vendor

Nothing to re-vendor, and no tag to bump by hand: release-please's release PR
rewrites the pinned tags in `picture-pipeline.yaml`, in `scripts/images.txt`
and everywhere else, and merging it publishes the images. See
`apps/README.md` → "Releasing the images". The tags in the table above are
the exception: a markdown table row cannot carry the block annotations, so
this file is not a release-please extra-file — its version is prose, kept
honest by review.

## Design decisions recorded here

- **This component ships its own `Namespace pipeline`**, plus the Broker, both
  ksvcs, the Trigger and the bucket Job. The catalog Application (sync-wave 3)
  adds `CreateNamespace=true` and — because Broker/Trigger/ksvc CRDs may still
  be landing — `SkipDryRunOnMissingResource=true`.
- **Broker `default` is in-memory** (`MTChannelBasedBroker` over the
  InMemoryChannel that knative-eventing defaults to). The `eventing.knative.dev/broker.class`
  annotation is redundant with `config-br-defaults` but kept explicit for
  teachability. In-memory means **no durability** — an imc-dispatcher
  restart drops in-flight events. Deliberate: this is a 4-hour lab, not
  Kafka school.
- **The Broker carries an explicit `spec.config` → ConfigMap
  `config-br-default-channel` in `knative-eventing`.** This is the
  race-proofing curation, and it is not optional: mt-broker-controller
  resolves the *cluster default* channel template once at startup into its
  config-store. ArgoCD routinely syncs this component while eventing is still
  installing, so that cache can come up empty and then every reconcile fails
  with `ChannelTemplateFailed: failed to find channelTemplate` — permanently,
  because nothing re-reads it. With an explicit `spec.config` the controller
  reads the ConfigMap through the live lister on each reconcile and recovers
  by itself as soon as it exists. Lose this and module 09 dies at "the Broker
  never becomes Ready", with a cause nobody finds in 4 hours.
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
- **Both ksvcs get the same four S3 env vars** —
  `S3_ENDPOINT=http://rustfs-svc.rustfs.svc.cluster.local:9000`,
  `S3_ACCESS_KEY`/`S3_SECRET_KEY`, `S3_BUCKET=images` — i.e. the *in-cluster*
  RustFS Service (unlike the portal, neither app talks to a browser, so
  neither needs the NodePort form). The uploader additionally gets
  `BROKER_URL`.
- **Resources are asymmetric on purpose**: uploader requests 50m/64Mi with a
  128Mi limit; the resizer has the same requests but a **256Mi** limit, because
  decoding a JPEG into a pixel buffer is the one memory-hungry step in the
  pipeline. Halve the resizer's limit and the capstone fails as an
  OOMKill on the *second* hop — after the upload appears to succeed.
- **Job `create-images-bucket`** carries the one thing GitOps can't: the
  S3 bucket. Same pinned `aws-cli` image and idempotent
  `head-bucket || create-bucket` pattern as `solutions/*/post.sh` and the
  platform-api composition. `backoffLimit: 20` + `restartPolicy: OnFailure`
  rides out RustFS still starting; no TTL so the completed Job persists and
  ArgoCD doesn't re-create it every reconcile. It needs
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (the same workshop creds, under
  the names the aws-cli reads) **and `AWS_REGION=us-east-1`** — the CLI
  refuses to sign a request without a region even though RustFS ignores it.
  Requests 50m/64Mi, limit 256Mi.
- S3 credentials `cloudbox`/`cloudbox123` are workshop-grade on purpose
  (ephemeral lab sandbox) and must match the rustfs component.
