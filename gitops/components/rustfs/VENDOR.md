# Vendored: rustfs

| | |
|---|---|
| Source chart | `rustfs/rustfs` **1.0.0-rc.2** from https://charts.rustfs.com |
| App version | **1.0.0-rc.2** (`docker.io/rustfs/rustfs:1.0.0-rc.2`, amd64+arm64, verified 2026-08-16) |
| Files | `rustfs.yaml` (rendered), `service-nodeport.yaml` (workshop addition) |

## Re-vendor

The recipe lives **once**, in the `curation` block further down this file —
`scripts/check-vendor-drift.sh` runs it, so it cannot rot into a stale copy of
itself. Re-vendoring is: reproduce the file with that recipe, re-apply the five
curations below, then `./scripts/check-vendor-drift.sh --only rustfs`.

Values rationale:
- **standalone mode** (the chart defaults to a 4-pod *distributed* StatefulSet!).
  Confirm after every re-vendor that the render is a single `Deployment` with
  `replicas: 1` and **no** `StatefulSet` — that is the one thing a values-key
  rename would silently take away. Re-confirmed on 1.0.0-rc.2: the render is
  six objects (ServiceAccount, Secret, ConfigMap, PVC, Service, Deployment),
  zero StatefulSets.
- `obs_log_directory: ""` disables the separate logs PVC → single 2Gi data
  PVC on `local-path`, and sends logs to stdout where `kubectl logs` and the
  OTel Collector can see them.
- `log_level: "info"` — plain level again as of 1.0.0-rc.2. It carried an
  EnvFilter workaround suffix on rc.1; see the history section below before
  re-adding one.
- `--no-hooks` drops the helm-test connection Pod (ArgoCD directory sources
  don't understand helm test hooks and would deploy it).
- init image pinned (`busybox:stable` upstream → `busybox:1.37.0`).
- Credentials `cloudbox`/`cloudbox123` are **workshop-grade and committed on
  purpose** (ephemeral lab sandbox); a comment in `rustfs.yaml` says the same.

What the render exposes, since the labs address it directly:

- **`9000` — the S3 endpoint.** In-cluster that is
  `http://rustfs-svc.rustfs.svc.cluster.local:9000`, which is what
  `S3_ENDPOINT` points at in portal, picture-pipeline and the module 03/04
  bucket Jobs. `service-nodeport.yaml` (a workshop addition, not in the chart)
  re-exposes the same port on **NodePort `30900`** = `NODEPORT_RUSTFS_S3` in
  `scripts/versions.env`, so presigned URLs and `s5cmd --endpoint-url` work from
  the laptop with no port-forward. Those two numbers must move together with
  that variable.
- **`9001` — the built-in console**, ClusterIP only. Deliberately not on a
  NodePort: the workshop's browser story is the Console (module 08) reading the
  bucket over S3, not RustFS's own UI. Reach it with a port-forward if you want
  to look.
- **Probes, both on :9000**: liveness `GET /health` (30 s delay, 5 s period),
  readiness `GET /health/ready` (10 s delay, 5 s period). `/health/ready` is the
  one that matters for the labs — it is what makes "rustfs is Ready" mean the
  object store will actually answer a `PutObject`, so the module 03 bucket Job
  and the picture pipeline do not race a half-started server.

Chart 1.0.0-rc.2 notes (vs the 1.0.0-rc.1 we vendored before):
- **No values key we set was renamed, removed, or moved**, and none is
  silently ignored. Checked by diffing the two chart sources in full: the only
  changes anywhere in the chart are `Chart.yaml`'s version/appVersion, one new
  README row, a new `RUSTFS_KMS_VAULT_KV_MOUNT` emission in `configmap.yaml`
  for the Vault **KV2** backend, and a new `gatewayApi.httpToHttpsRedirect`
  value gating the redirect HTTPRoute. `kms` and `gatewayApi` are both
  disabled for us, so neither reaches our render.
- The whole render delta is therefore **the version labels and the image
  tag** — nothing structural. Verified by rendering rc.1 and rc.2 with an
  otherwise identical values file and diffing.
- `secret.allowInsecureDefaults` is **unchanged** in rc.2: still present,
  still defaults to `false`, still `fail`s in `templates/secret.yaml` unless
  real credentials (or an `existingSecret`) are supplied. Ours are, so this
  stays a no-op — but a re-vendor that drops the `secret.rustfs` block will
  fail loudly instead of shipping `rustfsadmin/rustfsadmin`. Re-proved this
  pass by rendering rc.2 with the block removed: it errors, it does not
  silently substitute defaults.
- Still new since 0.8.0 and **deliberately left at defaults**: `pools`,
  `drivesPerNode`, `config.rustfs.scanner.*` (17 tuning knobs),
  `config.rustfs.obs_endpoint.*` (native OTLP export), `kms`, `mtls`,
  `gatewayApi`, `topologySpreadConstraints`, `pdb`.

## Workshop curation applied (re-apply after re-vendoring)

This list is **complete and mechanically verified**, and stays that way:
`./scripts/check-vendor-drift.sh --only rustfs` re-runs the recipe below and
fails on any hunk that is not one of the items here — four live, one retired.

1. **Credentials comment** above the `rustfs-secret` Secret.
2. **`argocd.argoproj.io/sync-options: Prune=false`** on the `rustfs-data`
   PVC, plus the comment explaining why there are two keep-annotations: the
   chart's `helm.sh/resource-policy: keep` is honored by Helm and **ignored by
   ArgoCD**, so without the ArgoCD one, disabling the rustfs app (`git rm` +
   push, `prune: true`) would delete the PVC and every uploaded image with it.
3. **The `RUSTFS_OBS_LOGGER_LEVEL` comment** in the `rustfs-config` ConfigMap
   — now three lines recording that the rc.1 log-flood workaround was removed
   in rc.2, so the next reader knows why a filter suffix is *not* there.
4. **RETIRED at the helm 4.2.4 bump (2026-08-17) — nothing to re-apply.**
   Was: *dropped the empty trailing YAML document* that the disabled KMS
   `secret.yaml` template emits (`---\n# Source: …/secret.yaml\n---`). helm
   4.2.4 fixed "vanishing empty lines", and one consequence is that the
   pristine render no longer emits that trailing document at all — the two
   blank lines it used to become now stay inside the preceding Secret instead
   (see curation 5). So `rustfs.yaml` matches upstream here and the `allow`
   line for it is gone. Nothing changed in the vendored file.
5. **Dropped the blank lines helm 4 emits before each `---` separator.** This
   is a renderer artifact, not a chart change: helm 3 did not emit it and the
   file was first vendored under helm 3. helm **4.2.4** emits *two* of them in
   one place (after the `rustfs-secret` Secret's `data:` block, where the
   retired curation 4's empty document used to be) and one everywhere else,
   which is why there are two whitespace hunk ids below rather than one.
   Purely cosmetic — strip it to keep re-vendor diffs readable.

### The same list, machine-readable

`scripts/check-vendor-drift.sh` re-runs the `helm template` below — chart,
version, flags and the whole values document — and diffs the result against
`rustfs.yaml`. Every hunk needs an `allow` line, and each one names the numbered
curation above rather than re-explaining it; an unlisted hunk fails (the chart
moved under a value we set, or someone hand-edited the render) and an `allow`
line whose hunk has **disappeared** fails too, because that is how curations get
lost in a re-vendor.

Curation 5 is why there are whitespace hunks here at all. This file was rendered
with helm **4.2.3** (the version pinned at the time), so it carries none of the
helm-3-era layout drift the other rendered components allow — the blank lines
below are stripped on purpose, by us, and hunks `39cdd0de` (one blank line) and
`0972f4d7` (two) are that strip and nothing else. The file has **not** been
re-rendered under helm 4.2.4; doing so would change nothing but whitespace, so
it is left for the next real chart bump.

```curation
render rustfs.yaml
chart     rustfs
repo      https://charts.rustfs.com
version   1.0.0-rc.2
release   rustfs
namespace rustfs
flags     --no-hooks
values
  replicaCount: 1
  image:
    initImage:
      repository: busybox
      tag: "1.37.0"
  mode:
    standalone:
      enabled: true
    distributed:
      enabled: false
  ingress:
    enabled: false
  secret:
    rustfs:
      access_key: cloudbox
      secret_key: cloudbox123
  config:
    rustfs:
      obs_log_directory: ""
      log_level: "info"
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 512Mi
  storageclass:
    name: local-path
    dataStorageSize: 2Gi

# --- accepted curation: one line per diff hunk (id, then why) ---
allow  rustfs.yaml  39cdd0de  curation 5 — the single blank line helm 4 emits before a `---`, stripped on purpose (4 hunks share this id: identical content). Not the same thing crossplane/zot/kagent allow — those are helm-3-era files nobody has re-rendered; this one WAS rendered with helm 4.2.3 and then stripped
allow  rustfs.yaml  641f354b  curation 1 — the WORKSHOP-GRADE CREDENTIALS comment above the `rustfs-secret` Secret
allow  rustfs.yaml  27322aea  curation 3 — the `RUSTFS_OBS_LOGGER_LEVEL` comment recording that the rc.1 log-flood workaround was removed in rc.2 (so nobody re-adds the EnvFilter suffix)
allow  rustfs.yaml  a81b83fa  curation 2 — the comment explaining why the PVC carries two keep-annotations (ArgoCD ignores helm.sh/resource-policy)
allow  rustfs.yaml  a3b94d12  curation 2 — `argocd.argoproj.io/sync-options: Prune=false` on the `rustfs-data` PVC; without it, disabling the app deletes the volume and every uploaded image
allow  rustfs.yaml  0972f4d7  curation 5 — the DOUBLE blank line helm 4.2.4 emits after the `rustfs-secret` Secret's `data:` block, where the retired curation 4's empty KMS document used to be. Stripped on the same grounds as `39cdd0de`; it is one hunk, not two, so it needs its own id
```

## History: the rc.1 log-flood workaround (upstream rustfs/rustfs#5927) — RESOLVED

**Do not re-add the EnvFilter suffix without re-measuring.** It is gone on
purpose and the numbers below are why.

RustFS 1.0.0-rc.1's `nsscanner_disk` span in `rustfs_scanner::scanner_io`
omitted `set_disks` from its `#[tracing::instrument]` skip list, so a
`Vec<Arc<Disk>>` was `Debug`-rendered into every span line — worst on
single-disk standalone deployments, our exact topology. From rc.1 we shipped
`log_level: "info,rustfs_scanner::scanner_io=warn"` to demote just that module.

Fixed upstream by PR
[#5933](https://github.com/rustfs/rustfs/pull/5933) ("fix(scanner): skip disk
inventory in scan spans", merged 2026-08-11, commit `727a10e1`), first
released in **1.0.0-rc.2** (2026-08-14) — confirmed as one of the 215 commits
in the `1.0.0-rc.1...1.0.0-rc.2` comparison, and issue #5927 is closed.

**Re-measured before removing the mitigation**, because a release note is not
evidence. Same harness as the original pass: a throwaway container with this
ConfigMap's env verbatim and the Deployment's pod hardening (UID/GID 10001,
read-only rootfs, all caps dropped, 512Mi limit), one `/data` volume, seeded
with **240 objects** via the AWS CLI, then a **300 s idle window** with the
container's stdout byte-counted live:

| image | `log_level` | store | idle stdout | longest line |
|---|---|---|---|---|
| `1.0.0-rc.1` | `info` | 240 objects | **7,668 MiB/h** | **326,600 B** |
| `1.0.0-rc.1` | `info,…scanner_io=warn` | 240 objects | 7.35 MiB/h | 3,921 B |
| **`1.0.0-rc.2`** | **`info`** ← what we ship | **240 objects** | **5.45 MiB/h** | **4,157 B** |
| `1.0.0-rc.2` | `info,…scanner_io=warn` | 240 objects | 6.37 MiB/h | 4,086 B |
| `1.0.0-rc.2` | `info` | **empty** | 1.21 MiB/h | 4,068 B |

Three things this shows, in order of importance:

1. **rc.2 at plain `info` is fixed** — 5.45 MiB/h against rc.1's 7,668, a
   ~1,400× drop, and the longest line falls from 326,600 B to 4,157 B. The
   disk inventory is out of the span, which is exactly what #5933 did.
2. **The workaround now buys nothing.** On rc.2, keeping the filter measured
   *6.37* MiB/h against 5.45 without it — the difference is run-to-run noise,
   not signal. A mitigation with no measurable effect is dead weight that
   would quietly suppress real scanner logging in an observability workshop.
3. **The empty-store control is why a smoke test cannot be trusted here.** At
   1.21 MiB/h an empty rc.2 store looks identical to a healthy seeded one —
   and an empty *rc.1* store looked fine too (2.27 MiB/h in the original
   pass). The flood only exists once the scanner has objects. **Always seed
   before measuring**; an attendee at minute 150 has objects.

The rc.1 figure here (7,668 MiB/h) is lower than the 30,030 MiB/h recorded in
the original pass. Same bug, same direction, different machine load and a
different point in the scan cycle — the absolute rate varies, the ~3-orders-of-
magnitude gap does not. Either number ends the argument.

Options considered and rejected while the bug was live, kept because they
would come back if a sibling bug appears in another scanner module:
- **`log_level: "warn"`** — stops the flood (0 MiB/h) but silences RustFS
  completely in a workshop that teaches observability and debugging.
- **A `filelog` exclusion in `gitops/components/otel-collector/`** — keeps the
  flood out of VictoriaLogs but not off the node: the runtime still writes and
  rotates it, and `kubectl -n rustfs logs` stays unusable.
- **A real `obs_log_directory`** — moves the flood onto disk, filling the 2Gi
  PVC in seconds, and hides RustFS from `kubectl logs` and the Collector.

Plan B (SeaweedFS, per RESEARCH.md switch triggers): re-vendor from the
`seaweedfs` chart with `allInOne.enabled=true` into this same directory and
keep the Service names stable for the labs.
