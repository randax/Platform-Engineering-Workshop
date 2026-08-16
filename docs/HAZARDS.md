# Known hazards

Everything we know is dangerous, deliberately weird, or unproven — with what
would go wrong, how you would notice, and what retires it.

Written during the pre-event bump pass on **2026-08-11**, three weeks before the
workshop (JavaZone, Sept 2–3). `docs/MAINTENANCE.md` is how pins get bumped;
this is what to be afraid of while doing it.

Status key: **LIVE** = a real risk today · **WATCH** = unproven, needs a
rehearsal to settle · **TRAP** = looks like a bug, is deliberate, do not "fix"

---

## WATCH — the RustFS scanner log flood is fixed; confirm it on a cluster

Upstream [rustfs/rustfs#5927](https://github.com/rustfs/rustfs/issues/5927).
`nsscanner_disk` omitted `set_disks` from its `#[tracing::instrument]` skip
list, so a `Vec<Arc<Disk>>` was Debug-rendered into every span line — **332,800
bytes per line**, several times a second. From 1.0.0-rc.1 we shipped
`log_level: "info,rustfs_scanner::scanner_io=warn"` to demote just that module.

**Fixed in 1.0.0-rc.2** (released 2026-08-14) by PR
[#5933](https://github.com/rustfs/rustfs/pull/5933) ("skip disk inventory in
scan spans", merged 2026-08-11, commit `727a10e1`, one of the 215 commits in
the `rc.1...rc.2` comparison; issue closed). **Pinned rc.2 and removed the
workaround on 2026-08-16, after re-measuring** — a release note is not
evidence. Idle stdout, our exact config and pod hardening, 300 s windows:

| image | `log_level` | store | idle stdout | longest line |
|---|---|---|---|---|
| `1.0.0-beta.8` | `info` | ~240 objects | 3.26 MiB/h | ~9 KB |
| `1.0.0-rc.1` | `info` | ~240 objects | **30,030 MiB/h** *(orig. pass)* | 332,800 B |
| `1.0.0-rc.1` | `info` | 240 objects | **7,668 MiB/h** *(re-measure)* | 326,600 B |
| `1.0.0-rc.1` | `info,…scanner_io=warn` | 240 objects | 7.35 MiB/h | 3,921 B |
| **`1.0.0-rc.2`** | **`info`** ← shipped | **240 objects** | **5.45 MiB/h** | **4,157 B** |
| `1.0.0-rc.2` | `info,…scanner_io=warn` | 240 objects | 6.37 MiB/h | 4,086 B |
| `1.0.0-rc.2` | `info` | **empty** | 1.21 MiB/h | 4,068 B |

On rc.2 the workaround measures *worse* than no workaround (6.37 vs 5.45 —
noise): it has nothing left to suppress, which is why it went rather than
being kept "just in case".

**The lesson that outlives the bug: it only floods once the scanner has
objects to scan.** An empty store reads 1.21 MiB/h on fixed rc.2 and read
2.27 MiB/h on flooding rc.1 — indistinguishable. An empty-cluster smoke test
cannot see this class of bug; an attendee at minute 150 can. Seed the store
first, always.

**Watch in rehearsal:** modules 03/04/09. Upload objects, then check log growth
stays in single MiB/hour. Not at boot — *after* objects exist. If it is back,
the mitigation history (EnvFilter directive, and the OTel `filelog` exclusion
and `obs_log_directory` options that were rejected and why) is in
`gitops/components/rustfs/VENDOR.md`.

**Do not mistake this for it:** rc.2 still Debug-renders a whole `ECStore`
(disk map and all) into `rustfs_ecstore::bucket::replication::replication_pool`
spans — a **1.5 MB single log line**, same shape of bug as #5927. It is
harmless because it is a *fixed boot cost, not a rate*: measured at exactly
**7 lines / ~6.2 MB within 9 ms of startup**, and the count stayed at 7
through 240 uploads and 120 s of idle. Worth re-checking only if it ever
starts scaling with operations.

## LIVE — RustFS is a prerelease, by choice

`1.0.0-rc.2` is an rc, on a component modules 03, 04 and 09 depend on. Chosen
deliberately by the maintainer with the above evidence in hand. RustFS is beta
by design in this workshop (`docs/RESEARCH.md` §2); SeaweedFS is Plan B.

#5927 is fixed, but it was a whole-class reminder: if a sibling lands in
another scanner module, the EnvFilter directive that fixed it targets one
module path, not a class of bug, and would need widening.

## WATCH — Cilium 1.20.0 datapath is unproven

Everything verified for the 1.19.5 → 1.20.0 bump was static: chart digest
cross-checked three ways, all eight `--set` values confirmed present in the
schema *and* landing in the render, KubePrism intact, capability list exactly
our 11. **Nothing proves the datapath comes up on a real Talos-in-Docker node.**

Blast radius is total: nodes never Ready, `wait_rollout kube-system
daemonset/cilium` times out, and nothing else in the day happens. If there is
one rehearsal slot, spend it here.

## WATCH — local-path-provisioner v0.0.37 is the wave-0 gate

v0.0.37's entire upstream diff is a new health server: port 8080, startup and
liveness on `/health`, **readiness on `/ready`** (a different path — easy to
mis-copy). `bootstrap-gitops.sh` installs this imperatively before GitOps
exists, and everything else queues behind it.

Probe budget ≈ 65s before restart against `wait_rollout`'s 300s × 2 — headroom
is comfortable. But if the health server misbehaves, bootstrap stalls at
"Installing local-path-provisioner" and nothing past module 02 runs.

## WATCH — Knative 1.23.0 kourier and the IPv6 stats listener

1.23.0 moves the Envoy **static** stats listener from `0.0.0.0` to `"::"`. A
static listener that cannot bind is fatal at process start, not degraded: the
readiness probe on `:8081` is never reached, the gateway crashloops, and module
06 loses all ingress.

**We curated it back to `0.0.0.0`.** Port 9000 is only the admin/stats scrape
target and nothing here reaches it over IPv6, so restoring the address proven in
1.22.1 costs nothing and removes an unprovable module-killer. This is a
curation upstream does not have — a maintenance cost, taken knowingly.

**Retire when:** a rehearsal shows the gateway healthy *and* `cat
/proc/net/if_inet6` inside the pod shows usable IPv6. Then drop it at the next
re-vendor.

## LIVE — VENDOR.md curation lists were wrong 11 times out of 19

A `VENDOR.md` that under-documents its curation is a landmine for the *next*
person to re-vendor: they follow the recipe, lose an undocumented edit, and
break a module silently.

All 19 components have now been audited. **11 were wrong**, and every one of the
first four was found by accident, while bumping that component for an unrelated
reason:

- `local-path-provisioner` — missing the PSA `privileged` namespace label, whose
  loss makes **every PVC hang Pending**
- `knative-serving` — missing the `config-domain` `sslip.io` entry and nine
  `config-observability` keys (module 06 and the module 09 trace waterfall)
- `knative-eventing` — missing six `config-observability` keys
- `nats` — documented about half the component: the whole metrics sidecar, its
  port and annotations, the probe split, the resource blocks
- `grafana`, `otel-collector`, `portal`, `picture-pipeline`, `backstage`,
  `application-xr` — gaps found in the full audit; `portal`'s RBAC list was
  actively stale
- only `cnpg-operator` was complete (it has no curation at all — byte-identical
  to upstream, now stated explicitly)

Two of those were worse than gaps: `backstage`'s VENDOR.md named the **wrong
Gitea admin** (`cloudbox` instead of `gitea_admin`), so a maintainer "fixing"
the manifest to match the doc would have broken the integration; and
`application-xr` documented a curation **that does not exist** (see the
`spec.env` TRAP below).

**The shape is always the same:** the doc was accurate the day it was written
and rotted at the next bump, because nothing ever compared it to anything.
Prose cannot stay honest about a file that changes for other reasons — which is
why the re-render gate and token-coverage lint exist. Do not rely on this
audit staying true; rely on the guards.

## LIVE — a wrong-architecture mirror serves happily

`cloudbox-init.sh` now copies tag-pinned images for the host architecture only
(that is what took the pre-pull from ~15.5 GB to ~7.5 GB). The failure mode is
nastier than a missing image: `create-cluster.sh` sets `skipFallback: false`, so
a **miss** is harmless — the node falls back to the real registry. A
**wrong-arch** mirror still answers, so there is no miss, no fallback, and pods
crashloop with exec-format errors. Offline. At the venue.

**Mitigation (shipped):** `install.sh --check` verifies every tag pin's
architecture against the **Docker daemon's** arch — not `uname -m`, because an
x86_64 Rosetta shell on Apple Silicon reports the wrong one.
`images-gate.yaml` separately requires every tag-pinned index to publish both
linux/amd64 and linux/arm64, so an upstream dropping an arch shows up in the
weekly report rather than on a laptop.

## TRAP — digest-pinned refs must keep the full multi-arch index

Do not "optimize" the digest-pinned refs in `cloudbox-init.sh` the way tag pins
were optimized. A pinned `@sha256:` names the **index**; a platform-filtered
copy stores a different digest, and the node's pull by the pinned digest 404s.

The clever version was tested and rejected: pushing the index byte-for-byte with
absent children works on containerd **1.7**, and fails on containerd **2.2.6** —
which is what Talos v1.13.x ships. containerd 2.x fetches every child manifest
in an index regardless of platform. Passing at home, failing at the venue.

## TRAP — things that look wrong and are not

| Looks like | Actually |
|---|---|
| `KUBERNETES_VERSION` is behind upstream | **Derived** from the Talos release. Raising it makes `create-cluster.sh` request control-plane images that are not in `images.txt` — and every other check stays green. `check-consistency.sh` now asserts the four control-plane refs match. Bump it *with* Talos, never ahead. |
| `docker.io/library/busybox:1.37.00` is a typo | Module 05 fault injection. Deliberately broken, never pre-pulled, excluded by name in `check-consistency.sh`. Never "fix" it. |
| Talos could go to 1.12.x | No. `cni: none` docker clusters hang — talos#12885. |
| kagent's latest release is v0.10.0-beta | Upstream does not mark its beta/rc tags as prereleases. `upstream.list` reads kagent from **tags**, stable-only. |
| CNPG is stuck on 1.28.x | Deliberate hold — the mature minor. 1.29/1.30 exist and are ignored by a `track` regex. |
| envoy is behind at v1.37.x | net-kourier ships `v1.37-latest`; we pin the exact patch it resolves to. A `track ^1\.37\.` regex stops the weekly report recommending 1.39. |
| Backstage is amd64-only | Upstream ships it that way; Apple Silicon runs it emulated. Listed in `MIRROR_ARCH_EXEMPT`. Under Colima it may need `--vm-type vz --vz-rosetta`. |
| `application-xr`'s `spec.env` does nothing | Correct — it is **RESERVED, not implemented**. The Composition emits no patch for it; the field stays in the XRD so the v2 append lands without an API break. The VENDOR.md claimed for months that it was "appended"; git history shows the patch never existed. The XRD description now says so. |
| `docker.io/grafana/grafana` vanished from `images.txt` | It was only the `FROM` line in `apps/grafana/Dockerfile`, consumed by CI. No pod ever pulled it. The deployed image is `ghcr.io/randax/cloudbox-grafana`. |

## WATCH — helm 4 on the apply path

`helm` is pinned to **4.2.3**, used by three real `helm upgrade --install` calls
(Cilium in `create-cluster.sh` and `kind-fallback.sh`, Gitea in
`bootstrap-gitops.sh`). Renders were verified identical to 3.21.3 — crossplane
and gitea byte-for-byte, cilium differing only by three empty-string ConfigMap
keys that helm 4 strips as null chart defaults, functionally inert.

The untested part is **apply**, not render. helm 4 defaults `--server-side` to
`auto`, which for a *fresh* release — every workshop cluster — resolves to
server-side apply. All three invocations therefore pass **`--server-side=false`**
explicitly, keeping helm 3's proven client-side path, so this is a
same-behaviour-newer-binary bump rather than a behaviour change.

**This is the first thing to revert if module 01 or 02 misbehaves** — set
`helm = "3.21.3"` in `mise.toml` and drop the three flags. Nothing in the repo
needs a helm 4 feature.

**Retire the flags when:** a full `bootstrap-test` is green with them removed.

## TRAP — Grafana must not be allowed to phone home at boot

`GF_INSTALL_PLUGINS=""` only empties the *user* install list. Grafana separately
background-installs drilldown apps compiled into the binary — 4 on 12.4.5, **6
on 13.1.3** — which offline means six failed calls to grafana.com per pod start,
each landing as `level=error … read-only file system`. `GF_PLUGINS_PREINSTALL_DISABLED=true`
removes all of it. Do not delete that env var; it was already needed at 12.4.5
and 13 made it worse.

Related, deliberate: `victoriametrics-logs-datasource` is held at **0.29.0**
though 0.30.1/0.31.0 exist — all three declare `>=10.4.0`, so nothing forces a
move and holding keeps the Grafana major a one-variable change.

## WATCH — smaller things the rehearsal settles

| What | Why it matters |
|---|---|
| **NATS 2.14 liveness** | 2.14 surfaces filestore I/O errors in `/healthz`, which our liveness probe reads. A full `local-path` PVC now **CrashLoops** the pod where 2.12 stayed silently up. |
| **BuildKit v0.32.2, module 07** | New variable is runc v1.4.3 under rootlesskit on the Talos kernel. Fails at daemon start if at all — unambiguous. |
| **zot v2.1.20 under chart 0.1.122** | The chart still declares appVersion v2.1.18; we override the image tag deliberately. Check anonymous push and the search/UI extensions on `:30500`. |
| **Grafana Explore deep-link** | `/explore?schemaVersion=1&orgId=1&panes={…}` is a frontend URL contract with no stability guarantee. Datasources and queries verified on 13.1.3; that pane rendering *prefilled* needs one human click. |
| **OTel 0.158.0 deprecation WARNs** | Expect 5 gateway / 3 agent `alias is deprecated` warnings. Attendees will read them in module 09 — consider pre-empting in the lab text. Legacy IDs stay on purpose: renaming makes the config unloadable on 0.149.0, breaking rollback. |

**Rollback hazards:** downgrading the OTel Collector below 0.156 needs
`/var/lib/otelcol` wiped. The kagent whitespace normalization produces a large
git diff that is a cluster no-op.

## TRAP — release-please cannot write `.github/workflows/**`

`GITHUB_TOKEN` is not permitted to modify workflow files. Adding one to
`extra-files` fails the whole run at tree creation with a bare
`Error adding to tree`. Do not put a workflow file in that list.

Separately: "GitHub Actions is not permitted to create or approve pull requests"
is a **repo setting**, not a code problem. It silently failed every release-please
run from 2026-07-19 until it was ticked on 2026-08-11.

## TRAP — the release/pin publish window (recurs every release)

A release PR rewrites all 15 first-party pins to the next version, but those
images only exist **after** the PR merges and `build-images` finishes. In
between, `images.txt` points at images that do not exist and
`cloudbox-init.sh`'s preflight fails, downloading nothing.

Hit once for real on 2026-08-11 (`cloudbox-grafana:v0.1.0` did not exist) and
navigated deliberately for v0.2.0 on 2026-08-16. **This is not a bug to fix —
it is inherent to pinning your own images.** The rule is procedural: merge the
release, wait for the build, verify every ref resolves, *then* pre-pull.

    while IFS= read -r ref; do crane manifest "$ref" >/dev/null 2>&1 \
      || echo "MISSING: $ref"; done < <(grep -vE '^\s*(#|\[|$)' scripts/images.txt)

Never hand a fresh laptop a pre-pull inside that window.

## Open question — why the AWS CLI?

`public.ecr.aws/aws-cli/aws-cli` is used by modules 03, 04 and 09 (and the
platform-api compositions) to prove bucket operations against RustFS — roughly
130 MB of the pre-pull. **No rationale is recorded anywhere in the repo.**

The defensible reading is that it is the point: RustFS is S3-compatible, so the
standard S3 client works unchanged, and that is the lesson. But note the
first-party apps use `minio/minio-go` instead, so the workshop demonstrates two
different S3 clients without saying why. Alternatives worth a thought: `s5cmd`
or `rclone` (much smaller), or `mc` (awkward — MinIO's community edition was
discontinued, which is the reason RustFS is here at all).

Either write the rationale down or change the tool. Right now a sharp attendee
asks "why am I typing `aws` in a workshop about not using AWS?" and the honest
answer is undocumented.

## Minor — `check-upstream.sh` prerelease-word gap

The semver comparison treats an unknown suffix as a build *flavor*
(`-rootless`, `-alpine`), which is correct and cannot under-report drift — this
was tested across all 49 suffix/version combinations the repo uses. But a suffix
that is *semantically* a prerelease and not in the known word list
(`-m1`, `-milestone2`, `-devel`, `-eap`) would be read as release-grade and
could under-report. **No pin here uses one.** Fix the word list if one ever
appears; do not "fix" the flavor-stripping.
