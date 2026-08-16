# Vendored: rustfs

| | |
|---|---|
| Source chart | `rustfs/rustfs` **1.0.0-rc.2** from https://charts.rustfs.com |
| App version | **1.0.0-rc.2** (`docker.io/rustfs/rustfs:1.0.0-rc.2`, amd64+arm64, verified 2026-08-16) |
| Files | `rustfs.yaml` (rendered), `service-nodeport.yaml` (workshop addition) |

## Re-vendor

```sh
helm repo add rustfs https://charts.rustfs.com && helm repo update
cat > /tmp/rustfs-values.yaml <<'VALUES'
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
VALUES
helm template rustfs rustfs/rustfs --version 1.0.0-rc.2 --namespace rustfs \
  --no-hooks -f /tmp/rustfs-values.yaml > rustfs.yaml
```

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

This list is **complete and mechanically verified**: `diff <the helm template
output above> rustfs.yaml` produces nothing outside the five items below.

1. **Credentials comment** above the `rustfs-secret` Secret.
2. **`argocd.argoproj.io/sync-options: Prune=false`** on the `rustfs-data`
   PVC, plus the comment explaining why there are two keep-annotations: the
   chart's `helm.sh/resource-policy: keep` is honored by Helm and **ignored by
   ArgoCD**, so without the ArgoCD one, disabling the rustfs app (`git rm` +
   push, `prune: true`) would delete the PVC and every uploaded image with it.
3. **The `RUSTFS_OBS_LOGGER_LEVEL` comment** in the `rustfs-config` ConfigMap
   — now three lines recording that the rc.1 log-flood workaround was removed
   in rc.2, so the next reader knows why a filter suffix is *not* there.
4. **Dropped the empty trailing YAML document** that the disabled KMS
   `secret.yaml` template emits (`---\n# Source: …/secret.yaml\n---`). Inert,
   but it is noise in a file attendees read.
5. **Dropped the blank line helm 4 emits before each `---` separator.** This
   is a renderer artifact, not a chart change: helm 3 did not emit it and the
   file was first vendored under helm 3. Purely cosmetic — strip it to keep
   re-vendor diffs readable.

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
