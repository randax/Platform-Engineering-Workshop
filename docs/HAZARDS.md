# Known hazards

Everything we know is dangerous, deliberately weird, or unproven — with what
would go wrong, how you would notice, and what retires it.

Written during the pre-event bump pass on **2026-08-11**, three weeks before the
workshop (JavaZone, Sept 2–3). `docs/MAINTENANCE.md` is how pins get bumped;
this is what to be afraid of while doing it.

Status key: **LIVE** = a real risk today · **WATCH** = unproven, needs a
rehearsal to settle · **TRAP** = looks like a bug, is deliberate, do not "fix"

---

## LIVE — RustFS 1.0.0-rc.1 floods logs at ~29 GiB/h

Upstream [rustfs/rustfs#5927](https://github.com/rustfs/rustfs/issues/5927).
`nsscanner_disk` omits `set_disks` from its `#[tracing::instrument]` skip list,
so a `Vec<Arc<Disk>>` is Debug-rendered into every span line — **332,800 bytes
per line**, several times a second.

Measured here, idle, our exact config:

| store state | 1.0.0-beta.8 | 1.0.0-rc.1 |
|---|---|---|
| empty | 3.57 MiB/h | 2.27 MiB/h |
| ~240 objects | 3.26 MiB/h | **30,030 MiB/h** |

**It only floods once the scanner has objects to scan.** An empty-cluster smoke
test cannot see this; an attendee at minute 150 can.

**Mitigation (shipped):** `gitops/components/rustfs/rustfs.yaml` sets
`log_level: "info,rustfs_scanner::scanner_io=warn"`. `RUSTFS_OBS_LOGGER_LEVEL`
accepts a full tracing EnvFilter directive, not just a bare level — that cuts it
to **5.72 MiB/h** while keeping ~15,700 INFO lines. A `filelog` exclusion in the
OTel Collector was rejected: it keeps the flood out of VictoriaLogs but the
runtime still writes 29 GiB/h to the attendee's disk and `kubectl logs` stays
unusable. A real `obs_log_directory` would fill the 2Gi PVC in seconds.

**Fixed upstream but not released.** PR
[#5933](https://github.com/rustfs/rustfs/pull/5933) merged to `main`
2026-08-11 01:01 UTC; the newest release is `1.0.0-rc.1` (2026-08-08), which
predates it. Release cadence has been roughly weekly (beta.10 → beta.11 →
beta.12 → rc.1 over four weeks), so a fixed build will *probably* exist before
the workshop — do not depend on it.

**Retire when:** a release containing #5933 is pinned. Then drop the filter
suffix back to plain `"info"` — the comment at the change site says so.

**Watch in rehearsal:** modules 03/04/09. Upload objects, then check log growth
stays in single MiB/hour. Not at boot — *after* objects exist.

## LIVE — RustFS is a prerelease, by choice

`1.0.0-rc.1` is an rc, on a component modules 03, 04 and 09 depend on. Chosen
deliberately by the maintainer with the above evidence in hand. RustFS is beta
by design in this workshop (`docs/RESEARCH.md` §2); SeaweedFS is Plan B.

If #5927 turns out to have siblings in other scanner modules, the EnvFilter
directive needs widening — it targets one module path, not a class of bug.

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

## LIVE — VENDOR.md curation lists have been wrong three times

A `VENDOR.md` that under-documents its curation is a landmine for the *next*
person to re-vendor: they follow the recipe, lose an undocumented edit, and
break a module silently.

Found and fixed this pass:
- `knative-serving` — missing the `config-domain` `sslip.io` entry and nine
  `config-observability` keys (module 06 and the module 09 trace waterfall)
- `knative-eventing` — missing six `config-observability` keys
- `local-path-provisioner` — missing the PSA `privileged` namespace label, whose
  loss makes **every PVC hang Pending**

**Not yet audited:** every other `gitops/components/*/VENDOR.md`. The check is
mechanical — diff the vendored file against pristine upstream at the pinned
version and confirm every difference is a documented curation. Worth doing
before the event.

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
| `docker.io/grafana/grafana` vanished from `images.txt` | It was only the `FROM` line in `apps/grafana/Dockerfile`, consumed by CI. No pod ever pulled it. The deployed image is `ghcr.io/randax/cloudbox-grafana`. |

## TRAP — release-please cannot write `.github/workflows/**`

`GITHUB_TOKEN` is not permitted to modify workflow files. Adding one to
`extra-files` fails the whole run at tree creation with a bare
`Error adding to tree`. Do not put a workflow file in that list.

Separately: "GitHub Actions is not permitted to create or approve pull requests"
is a **repo setting**, not a code problem. It silently failed every release-please
run from 2026-07-19 until it was ticked on 2026-08-11.

## LIVE — the release/pin publish window

Release PR #184 rewrites all 15 first-party pins from `:v0.1.0` to `:v0.2.0`,
but those images only exist **after** the PR merges. Between the two,
`images.txt` points at images that do not exist and `cloudbox-init.sh`'s 67-ref
preflight fails, downloading nothing.

Never start a fresh-laptop pre-pull inside that window. Merge the release, let
`build-images` finish, verify all refs resolve, then pre-pull.

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
