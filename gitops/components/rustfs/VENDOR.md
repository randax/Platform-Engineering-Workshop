# Vendored: rustfs

| | |
|---|---|
| Source chart | `rustfs/rustfs` **1.0.0-rc.1** from https://charts.rustfs.com |
| App version | **1.0.0-rc.1** (`docker.io/rustfs/rustfs:1.0.0-rc.1`, amd64+arm64, verified 2026-07-13) |
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
    log_level: "info,rustfs_scanner::scanner_io=warn"
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
helm template rustfs rustfs/rustfs --version 1.0.0-rc.1 --namespace rustfs \
  --no-hooks -f /tmp/rustfs-values.yaml > rustfs.yaml
```

Values rationale:
- **standalone mode** (the chart defaults to a 4-pod *distributed* StatefulSet!).
  Confirm after every re-vendor that the render is a single `Deployment` with
  `replicas: 1` and **no** `StatefulSet` — that is the one thing a values-key
  rename would silently take away.
- `obs_log_directory: ""` disables the separate logs PVC → single 2Gi data
  PVC on `local-path`, and sends logs to stdout where `kubectl logs` and the
  OTel Collector can see them.
- `log_level` — see the workaround note below; it is **not** a plain level.
- `--no-hooks` drops the helm-test connection Pod (ArgoCD directory sources
  don't understand helm test hooks and would deploy it).
- init image pinned (`busybox:stable` upstream → `busybox:1.37.0`).
- Credentials `cloudbox`/`cloudbox123` are **workshop-grade and committed on
  purpose** (ephemeral lab sandbox); a comment in `rustfs.yaml` says the same.

Chart 1.0.0-rc.1 notes (vs the 0.8.0 we vendored before):
- **No values key we set was renamed**, and none is silently ignored — the
  render was checked key by key: `replicas: 1`, `RUSTFS_ADDRESS`,
  `RUSTFS_CONSOLE_ADDRESS`, `RUSTFS_OBS_LOG_DIRECTORY`,
  `RUSTFS_OBS_LOGGER_LEVEL`, `RUSTFS_VOLUMES: "/data"`, ports 9000/9001,
  `RUSTFS_ACCESS_KEY`/`RUSTFS_SECRET_KEY`, `storageClassName: local-path`,
  `storage: 2Gi`, both probes, and the resource block all land unchanged.
- The whole upstream render delta is: the version labels, the image tag, and
  a new `serviceAccountName: rustfs` on the pod spec (the chart already
  created that ServiceAccount; now it actually uses it).
- New in this chart and **deliberately left at defaults**: `pools`,
  `drivesPerNode`, `config.rustfs.scanner.*` (17 tuning knobs),
  `config.rustfs.obs_endpoint.*` (native OTLP export), `kms`, `mtls`,
  `gatewayApi`, `topologySpreadConstraints`, `pdb`.
- `secret.allowInsecureDefaults` is new and defaults to `false`: the chart now
  **refuses to render** unless real credentials are supplied. Ours are, so
  this is a no-op — but a re-vendor that drops the `secret.rustfs` block will
  now fail loudly instead of shipping `rustfsadmin/rustfsadmin`.

## Workshop curation applied (re-apply after re-vendoring)

This list is **complete and mechanically verified**: `diff <the helm template
output above> rustfs.yaml` produces nothing outside the four items below.

1. **Credentials comment** above the `rustfs-secret` Secret.
2. **`argocd.argoproj.io/sync-options: Prune=false`** on the `rustfs-data`
   PVC, plus the comment explaining why there are two keep-annotations: the
   chart's `helm.sh/resource-policy: keep` is honored by Helm and **ignored by
   ArgoCD**, so without the ArgoCD one, disabling the rustfs app (`git rm` +
   push, `prune: true`) would delete the PVC and every uploaded image with it.
3. **The `RUSTFS_OBS_LOGGER_LEVEL` workaround comment** in the `rustfs-config`
   ConfigMap (the *value* comes from the values file above; only the comment
   is curation). See below.
4. **Dropped the empty trailing YAML document** that the disabled KMS
   `secret.yaml` template emits (`---\n# Source: …/secret.yaml\n---`). Inert,
   but it is noise in a file attendees read.

## ⚠️ The log-flood workaround (upstream rustfs/rustfs#5927)

**Remove this the moment #5927 is fixed and we bump past it** — set
`config.rustfs.log_level` back to plain `"info"` and delete the comment block
in `rustfs.yaml`.

RustFS 1.0.0-rc.1's `nsscanner_disk` span in `rustfs_scanner::scanner_io`
omits `set_disks` from its `#[tracing::instrument]` skip list, so a
`Vec<Arc<Disk>>` is `Debug`-rendered into every span line. Upstream says it is
worst on single-disk standalone deployments — our exact topology.

Measured on this repo's config (Docker, one `/data` volume, the same env this
ConfigMap ships), **idle, with ~240 objects in the store**:

| image | idle stdout | longest log line |
|---|---|---|
| `1.0.0-beta.8` (previous pin) | **3.26 MiB/h** | ~9 KB |
| `1.0.0-rc.1`, `log_level: "info"` | **~30,030 MiB/h (≈29 GiB/h)** | **332,800 B** |
| `1.0.0-rc.1`, `log_level: "info,rustfs_scanner::scanner_io=warn"` | **5.72 MiB/h** | **9,313 B** |

With an **empty** store both versions are quiet (beta.8 3.57 MiB/h, rc.1
2.27 MiB/h) — the flood only starts once the scanner has something to scan,
which is why a short smoke test misses it entirely and an attendee at minute
150 does not.

`RUSTFS_OBS_LOGGER_LEVEL` accepts a **tracing `EnvFilter` directive**, not
just a bare level — verified by running all three candidates side by side on
rc.1, same seeded store, same 300 s window:

| `log_level` | idle stdout | INFO lines kept |
|---|---|---|
| `info` (chart default) | ~30,030 MiB/h | all — and unusable |
| **`info,rustfs_scanner::scanner_io=warn`** ← what we ship | **5.72 MiB/h** | **~15,700** |
| `info,rustfs_scanner=warn` | 2.83 MiB/h | ~15,600 |
| `warn` | 0 MiB/h | 0 |

That is a **~5,250× reduction** while staying in the same order of magnitude
as the old beta.8 pin (3.26 MiB/h) and keeping every INFO line of real
S3/startup logging for the labs to read. We take the narrowest filter that
fixes the bug — `scanner_io` is the exact module named in #5927, so
`rustfs_scanner::scanner` keeps logging its cycle messages at INFO.

Options considered and rejected:
- **`log_level: "warn"`** — also stops the flood (0 MiB/h, 0 INFO lines), but
  silences RustFS completely in a workshop that teaches observability and
  debugging. Wrong trade.
- **A `filelog` exclusion for rustfs pods in
  `gitops/components/otel-collector/collector-agent.yaml`** — keeps the flood
  out of VictoriaLogs but not off the node: the container runtime still writes
  and rotates ~29 GiB/h, burning disk I/O and CPU on the attendee's laptop,
  and `kubectl -n rustfs logs` stays unusable. It also *removes* RustFS from
  the observability lab, which is teaching material. Fixing it at source is
  strictly better and needs no change to another component.
- **A real `obs_log_directory`** — moves the flood onto disk. At ~29 GiB/h it
  would fill the 2Gi data PVC in seconds, so it would need its own large PVC,
  and it *still* burns the disk. Also hides RustFS from `kubectl logs` and
  from the OTel Collector. Strictly worse.

Plan B (SeaweedFS, per RESEARCH.md switch triggers): re-vendor from the
`seaweedfs` chart with `allInOne.enabled=true` into this same directory and
keep the Service names stable for the labs.
