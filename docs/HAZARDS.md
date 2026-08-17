# Known hazards

Everything we know is dangerous, deliberately weird, or unproven — with what
would go wrong, how you would notice, and what retires it.

Written during the pre-event bump pass on **2026-08-11**, three weeks before the
workshop (JavaZone, Sept 2–3), and rewritten after the first full end-to-end
rehearsal on **2026-08-17**: modules 00→10 on one Apple Silicon laptop (Colima,
8 CPU / 15.6 GiB), **11/11 `verify.sh` exit 0**, 21/21 ArgoCD Applications
Synced+Healthy, Talos v1.13.8 / Kubernetes v1.36.2 / containerd 2.2.6, and
**~16 minutes of total script time against the 240-minute budget** — the machine
is not the constraint. It also found three blockers, two of which no CI job we
have can see. `docs/MAINTENANCE.md` is how pins get bumped; this is what to be
afraid of while doing it.

Status key: **LIVE** = a real risk today · **WATCH** = unproven, needs a
rehearsal to settle · **PROVEN ONCE** = came out green in the 2026-08-17
rehearsal, on one machine, one architecture — settled, not proven ·
**TRAP** = looks like a bug, is deliberate, do not "fix"

---

## LIVE — every node container is capped at 2.0 CPUs, whatever the laptop has

`talosctl cluster create docker` defaults **`--cpus-controlplanes` and
`--cpus-workers` to `2.0`** (its own `--help` says so), and
`scripts/create-cluster.sh` passes neither — it raises `--memory-controlplanes` /
`--memory-workers` deliberately and says nothing about CPU. So the entire
Kubernetes cluster runs inside a **4-CPU budget** no matter how many cores the
machine has:

    docker inspect cloudbox-worker-1 --format '{{.HostConfig.NanoCpus}}'
    2000000000                                     # = 2.0 CPUs
    grep -n MIN_CPUS scripts/versions.env
    99:MIN_CPUS="4"                                # the only CPU number in the repo

It is even in `talosctl`'s own creation summary (`CPU 2.00` per node), where
nobody reads it as a limit.

**What it does.** Everything schedules onto the one untainted worker. Modules
00–09 each passed on an 8-core machine without a hiccup, but at module 10's
canonical end state — 18 wave apps plus kagent, NATS and Backstage, 21 apps and
~125 containers — the worker ran out of CPU and the cluster came apart: kubelet
`HEALTH Fail` (`/healthz: context deadline exceeded`), `cloudbox-worker-1
NotReady`, then `kubectl` itself failing with `TLS handshake timeout` for tens of
minutes. The decisive reading, from inside the Colima VM:

    /proc/pressure/cpu:     some avg10=98.72 avg60=97.89 avg300=96.02
    /proc/pressure/io:      some avg10=2.56
    /proc/pressure/memory:  some avg10=0.00        full avg10=0.00

**98.7 % of the time some task is stalled waiting for CPU while the VM is only
~23 % busy and memory pressure is exactly zero** (worker 4.5/6 GiB, CP 3.2/4 GiB,
9.4 GB free). High CPU pressure + low absolute utilisation + no memory pressure
is cgroup throttling, not a machine that is too small.

**You cannot rescue it afterwards.** `docker update --cpus 3` /
`--cpus 4` on the live containers dropped pressure 98.7 → ~92 but the cluster did
**not** come back within the next ~10 minutes; once kubelet is behind on ~125
containers the backlog outlives the fix, and draining it took ~20–30 minutes. The
caps have to be right *before* the load arrives.

**Unresolved — this is a maintainer decision, not a patch.** Fixing it collides
with the published spec: `MIN_CPUS="4"` is a promise (principle 12, honest
specs), and if the worker needs more than 2 CPUs of its own to hold the full
stack then a 4-core laptop cannot run the stretch modules and the minimum has to
say so. Nobody has yet measured what the right numbers are. Options, in the order
worth considering: (1) add `TALOS_CPUS_CONTROLPLANE` / `TALOS_CPUS_WORKER` to
`versions.env` and pass the flags, sized from the host core count rather than
fixed; (2) state in modules 06–10's prerequisites that the full stack needs more
than the core-path minimum, and raise `MIN_CPUS` for the stretch path; (3) give
the observability stack resource requests so the scheduler refuses instead of
thrashing. Nothing bounds over-commit today.

**Read the currently-running rehearsal cluster with that in mind:** its 21/21
healthy state is on **hand-raised caps (3 CP / 4 worker)**, set with `docker
update` after the wedge. That is not what an attendee's `create-cluster.sh`
produces. Note also that `install.sh --check` verifies the *host* has ≥4 CPUs and
never mentions that only 4 reach the cluster regardless.

## TRAP — a green `bootstrap-test.yaml` means "the workshop works on Linux"

`bootstrap-test.yaml` runs on `ubuntu-latest`, where the host routes straight
into the Talos docker network. **macOS, Windows, and every Docker
Desktop / OrbStack / Colima host does not** — and macOS is a fully supported
platform in the published matrix (`docs/PRINCIPLES.md` §12) on which most of a
JavaZone room will be sitting. Both blockers the 2026-08-17 rehearsal found were
invisible to CI *by construction*:

- **`create-cluster.sh` could not finish on macOS at all** (fixed `1129983`).
  `talosctl cluster create` merges a working kubeconfig
  (`https://127.0.0.1:<published port>`); the script's very next line,
  `talosctl kubeconfig --force`, overwrites it with the machine config's
  `cluster.controlPlane.endpoint` = **`https://10.5.0.2:6443`**, an address
  inside the Talos docker network. Linux routes there, laptops do not, so every
  `kubectl` call blocks. Cilium never installs; nothing past module 01 happens.
  Worse, the wait loop had no `--request-timeout`, so `kubectl` blocked on the
  ~75 s OS TCP connect timeout per attempt: `seq 1 60` × `sleep 2` promised
  "2 minutes" and was really ~77 minutes of frozen terminal with no error. Fixed
  by pointing kubeconfig at `docker port <cp> 6443/tcp` (talosctl already puts
  `127.0.0.1` in the API server certSANs, so it is valid on Linux too) plus
  `--request-timeout=5s` so the timeout matches its message.
- **`destroy && create` failed on the second cluster of the day** (fixed
  `3a7848f`). `talosctl config remove` **refuses to remove the currently-selected
  context and still exits 0** ("skipping removal of current context …"), and
  `destroy-cluster.sh` discarded its output — so the context was never removed,
  the next `talosctl cluster create` found the name taken and renamed **the new**
  context to `cloudbox-1`, and every `talosctl --context cloudbox` in
  `create-cluster.sh` then dialled the destroyed cluster (`connection refused`,
  exit 1, before Cilium). This broke `catch-up.sh --rebuild` — the recovery path,
  i.e. the one thing reserved for people who are already in trouble. A CI runner
  creates exactly one cluster and is then discarded, so it can never see this.

**The standing lesson: rehearse on a Mac before the event, and specifically
rehearse the *second* cluster, not just the first.** A macOS job, or at minimum a
`destroy && create` cycle appended to `bootstrap-test.yaml`, would close the two
gaps that hid these. Until then, green CI is evidence about Linux and nothing
else.

## PROVEN ONCE — the RustFS scanner log flood is fixed, and confirmed on a cluster

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
evidence. Idle stdout, our exact config and pod hardening, 300 s windows on the
bench; the last row is the live cluster over 60 minutes:

| image | `log_level` | store | idle stdout | longest line |
|---|---|---|---|---|
| `1.0.0-beta.8` | `info` | ~240 objects | 3.26 MiB/h | ~9 KB |
| `1.0.0-rc.1` | `info` | ~240 objects | **30,030 MiB/h** *(orig. pass)* | 332,800 B |
| `1.0.0-rc.1` | `info` | 240 objects | **7,668 MiB/h** *(re-measure)* | 326,600 B |
| `1.0.0-rc.1` | `info,…scanner_io=warn` | 240 objects | 7.35 MiB/h | 3,921 B |
| **`1.0.0-rc.2`** | **`info`** ← shipped | **240 objects** | **5.45 MiB/h** | **4,157 B** |
| `1.0.0-rc.2` | `info,…scanner_io=warn` | 240 objects | 6.37 MiB/h | 4,086 B |
| `1.0.0-rc.2` | `info` | **empty** | 1.21 MiB/h | 4,068 B |
| **`1.0.0-rc.2`** | **`info`** | **on cluster, 247 objects** | **3.44 MiB/h** | **4,158 B** |

On rc.2 the workaround measures *worse* than no workaround (6.37 vs 5.45 —
noise): it has nothing left to suppress, which is why it went rather than
being kept "just in case".

The last row is the 2026-08-17 rehearsal — the measurement this entry existed to
demand, taken on the live cluster after modules 03/04/09 had put 247 objects in
the store (241 in `app-assets`, 6 in `images` from the capstone), same pod, 0
restarts, 2h+ old. **3.44 MiB/hour** over 60 minutes against the bench figure of
5.45, and a longest line of **4,158 B against the recorded 4,157 B** — one byte
apart. The #5927 shape (332,800-byte lines) is gone: the biggest line in an hour
is 4 KB. `rustfs_scanner::scanner_io` is still the chattiest target (502
lines/hour), so the EnvFilter directive would still have something to bite on if
it regressed. Over a 240-minute workshop this is ~14 MiB of container log.

**One measurement trap the rehearsal exposed: window length matters as much as
seeding.** With those same 247 objects present, a 300-second window read **0.06
MiB/hour** — the scanner runs on a cadence, so a short window lands between
passes and reads clean. 30 min → 2.98 MiB/h, 60 min → 3.44 MiB/h. During the
240-object upload burst it was 27.8 MiB/h. Measure for half an hour, not five
minutes.

**The lesson that outlives the bug: it only floods once the scanner has
objects to scan.** An empty store reads 1.21 MiB/h on fixed rc.2 and read
2.27 MiB/h on flooding rc.1 — indistinguishable. An empty-cluster smoke test
cannot see this class of bug; an attendee at minute 150 can. Seed the store
first, always.

**Re-check at every RustFS bump** the same way: modules 03/04/09, upload objects,
then watch for half an hour and require single MiB/hour. Not at boot — *after*
objects exist. If it is back, the mitigation history (EnvFilter directive, and
the OTel `filelog` exclusion and `obs_log_directory` options that were rejected
and why) is in `gitops/components/rustfs/VENDOR.md`.

**Do not mistake this for it:** rc.2 still Debug-renders a whole `ECStore`
(disk map and all) into `rustfs_ecstore::bucket::replication::replication_pool`
spans — a **1.5 MB single log line**, same shape of bug as #5927. It is
harmless because it is a *fixed boot cost, not a rate*: measured on the bench at
exactly **7 lines / ~6.2 MB within 9 ms of startup**, and the count stayed at 7
through 240 uploads and 120 s of idle. The rehearsal reproduced it on-cluster —
**6 lines over 100 KB, longest 1,556,132 B, ~6.7 MB in the first seconds** — and
confirmed it does not scale: over the following hour of real traffic no line ever
exceeded 4,417 B. kubelet rotation then discards the burst, so `kubectl logs`
reads 556 bytes a minute later. Worth re-checking only if it ever starts scaling
with operations.

## LIVE — RustFS is a prerelease, by choice

`1.0.0-rc.2` is an rc, on a component modules 03, 04 and 09 depend on. Chosen
deliberately by the maintainer with the above evidence in hand. RustFS is beta
by design in this workshop (`docs/RESEARCH.md` §2); SeaweedFS is Plan B. It held
up in the 2026-08-17 rehearsal — modules 03, 04 and 09 all green, the same pod
alive 2h+ with **0 restarts**, presigned URLs and the capstone's thumbnail path
working — which settles the log flood, not the prerelease.

#5927 is fixed, but it was a whole-class reminder: if a sibling lands in
another scanner module, the EnvFilter directive that fixed it targets one
module path, not a class of bug, and would need widening.

## PROVEN ONCE — Cilium 1.20.0 datapath comes up on Talos-in-Docker

Everything verified for the 1.19.5 → 1.20.0 bump was static: chart digest
cross-checked three ways, all eight `--set` values confirmed present in the
schema *and* landing in the render, KubePrism intact, capability list exactly
our 11. Nothing proved the datapath — until 2026-08-17, on Talos v1.13.8 /
arm64:

- `wait_rollout kube-system daemonset/cilium` passed **first try, ~50 s**; both
  nodes `Ready` at 61 s of age. `cilium status`: agent, operator and
  `cilium-envoy` DaemonSets all 2/2, 2/2 pods managed, chart 1.20.0.
- `cilium-dbg status` from inside the agent: **`KubeProxyReplacement: True`**
  `[eth0 10.5.0.2 (Direct Routing)]`, `routing-mode=tunnel`/vxlan,
  `ipam=kubernetes`, zero kube-proxy pods, CoreDNS Available.
- KubePrism intact — `KUBERNETES_SERVICE_HOST=localhost` / `_PORT=7445` on both
  the agent DaemonSet and the operator Deployment, `talosctl get
  kubeprismstatuses` → `127.0.0.1:7445 HEALTHY true`. **Those land as env vars,
  not `cilium-config` keys** — worth knowing when checking by hand.
- The **policy** path works too, not just connectivity: module 05's fault 03 is a
  NetworkPolicy fault, and it both enforced while injected and stopped enforcing
  after the fix, inside the verify poll window.

Blast radius if a future bump breaks it is still total: nodes never Ready,
`wait_rollout` times out, and nothing else in the day happens. One machine, one
architecture — re-run module 01 on the next bump before believing it again.

## PROVEN ONCE — local-path-provisioner v0.0.37 is still the wave-0 gate

v0.0.37's entire upstream diff is a new health server: port 8080, startup and
liveness on `/health`, **readiness on `/ready`** (a different path — easy to
mis-copy). `bootstrap-gitops.sh` installs this imperatively before GitOps
exists, and everything else queues behind it. If the health server misbehaves,
bootstrap stalls at "Installing local-path-provisioner" and nothing past module
02 runs.

2026-08-17, in `bootstrap-gitops.sh`'s 54 seconds: the split is **not**
mis-copied (`startup=/health live=/health ready=/ready`), the deployment went
`Progressing` → `Available` in **~10 seconds** with **0 restarts**, and the PSA
`privileged` namespace label — the curation whose loss makes every PVC hang
Pending — is present. Gitea's 5Gi PVC `Bound` within the same minute. Against
`wait_rollout`'s 300 s × 2 the "probe budget ≈ 65 s" worry is a non-event.

## PROVEN ONCE — Knative 1.23.0 kourier, and the IPv6 curation is RETIRED

1.23.0 moves the Envoy **static** stats listener from `0.0.0.0` to `"::"` +
`ipv4_compat: true`. A static listener that cannot bind is fatal at process
start, not degraded: the readiness probe on `:8081` is never reached, the gateway
crashloops, and module 06 loses all ingress. **We curated it back to `0.0.0.0`**
because that failure mode could not be settled by reading YAML.

**With the curation, module 06 worked:** gateway **1/1 within ~20 s** of the pod
appearing, 0 restarts, all five knative-serving Deployments 1/1 within 12 s, and
`curl -H 'Host: hello.demo.127.0.0.1.sslip.io' http://localhost:31080` returned
`Hello your own cloud!` (200, 0.694 s warm); scale-to-zero observed after ~30 s
of silence.

**The curation is gone as of 2026-08-17** — `kourier.yaml` carries upstream's
`"::"` + `ipv4_compat: true` verbatim, and the two `allow` lines for it are out
of the component's ```curation block (kourier.yaml: 8 hunks → 6, gate green).
The circumstantial retire condition was already recorded: inside the gateway pod
`/proc/net/if_inet6` is populated (lo + eth0 `fe80::…`), `bindv6only=0` and
`disable_ipv6=0` on all/lo/eth0, and `argocd-server` on the same cluster and CNI
holds real `[::]:8080` / `[::]:8083` listeners. But that only proved the netns
*would* allow it. **What retires it is the direct test, run on the live rehearsal
cluster** (Talos v1.13.8 / Cilium 1.20.0 / arm64, ArgoCD auto-sync suspended for
the window, the bootstrap ConfigMap applied by hand, the gateway rolled):

- a **freshly created** gateway pod reached **1/1 Running with 0 restarts** on
  the `"::"` bootstrap — no crashloop, no bind error anywhere in its log;
- inside that pod, `awk '$4=="0A"' /proc/net/tcp6` shows **eight
  `00000000000000000000000000000000:2328` rows** — `[::]:9000`, one
  SO_REUSEPORT socket per Envoy worker. **The static listener binds the IPv6
  wildcard here.** That is the fact the curation had made unobservable;
- the IPv4 side is untouched: 8× `:8080`, 8× `:8081`, 8× `:8090` (the dynamic
  xDS listeners) and `127.0.0.1:9901` (admin);
- the stats port still works **over IPv4**, v4-mapped through `ipv4_compat`:
  the OTel Collector's `GET /stats/prometheus` answers **200** with ~197 KB
  every 30 s;
- `curl -H 'Host: hello.demo.127.0.0.1.sslip.io' http://localhost:31080` returned
  `Hello your own cloud!` **200** repeatedly (51 s on the scale-from-zero call,
  then 0.09–2.9 s).

**If this ever regresses, the symptom is immediate and unmistakable:** the
static listener cannot bind → `3scale-kourier-gateway` crashloops at process
start (bind / "Address family not supported" in `kubectl logs`, readiness on
`:8081` never reached) → **module 06 loses all ingress**. The fix is to put
`address: 0.0.0.0` back and drop `ipv4_compat` — but check
`/proc/net/if_inet6` and `bindv6only` in the pod first, because the real question
would be what took IPv6 out of the netns.

**Two honest caveats.** (1) One machine, one architecture, one CNI version —
settled, not proven; re-run module 06 on the next Knative or Cilium bump. (2) The
test ran against an already-loaded cluster and **the CPU cap hazard at the top of
this file dominated it**: the gateway pod sat in `ContainerCreating` for ~11
minutes waiting for the Cilium CNI ADD, and the *old* pod restarted twice on
liveness `504`/timeout while it waited (both exits code 0 "Completed" —
kubelet-initiated, not Envoy). None of that is about IPv6; all of it is what a
saturated 4-CPU worker looks like. Do not read those restarts as evidence
against the retirement — read them as more evidence for fixing the CPU caps.

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

**The same shape turned up once more on 2026-08-17, in code rather than prose.**
The Console's Workshop page — advertised in `lab/README.md` as "a live dashboard
of which modules your cluster has reached" — could never mark module 04 Done:
`apps/portal/internal/web/workshop.go` listed `WorkshopDatabases` **cluster-wide**
while the portal's only grant is the namespaced Role module 08 hands it, so the
403 zeroed `WDBCount` and the row could score at most 1/2. It read *In progress*
on a cluster with crossplane Synced/Healthy, two Ready WorkshopDatabases and
`lab/04-self-service/verify.sh` at 10/10. Fixed `c1faf23` by scoping to `demo` —
which is what the field's own comment (`// WorkshopDatabases in ns demo`) and the
row's own hint already claimed. **It is Go source, so it needs a portal release to
reach `ghcr.io/randax/cloudbox-portal` before anyone sees the fix**; until then the
deployed Console still shows the old behaviour.

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

**The other half of offline-first is the reaches nothing gates, and the 2026-08-17
rehearsal found the earlier leak fix was incomplete.** `solutions/module-07/post.sh`
still copied `docker.io/library/busybox:1.37.0` straight from Docker Hub, and
`solutions/module-{08,09,10}/post.sh` all chain into it — so **every `catch-up.sh`
from module 07 onward** depended on the one registry that is rate-limited at the
venue, on the recovery path, at the venue, for someone already behind. What made
it invisible is that its sibling `lab/07-ci/solve.sh` had *already* been fixed to
source `localhost:5001/library/busybox:1.37.0` from the mirror with a fallback and
a warning: the earlier fix landed in the lab and not in the solution. Fixed
`941d043` by copying that logic verbatim. **When auditing internet reaches, grep
`lab/` and `solutions/` — a fixed lab says nothing about its `post.sh`.** CI never
saw it because CI runs online, where both sources work.

Still open, same class: `install.sh --check` proves the mirror is reachable from
container context with `docker run … docker.io/library/busybox:1.37.0`, which is
in `images.txt`'s `[mirror]` section but **not `[host]`**, so `cloudbox-init.sh`
never `docker pull`s it. Invisible in the documented order (the first `--check` at
home warms the host cache), but it bites anyone whose first `--check` is offline —
including a helper debugging an attendee's laptop in the room. Adding the ~2 MB
image to `[host]` closes it, at the cost of touching the pin surface.

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
| Backstage is amd64-only | Upstream ships it that way; Apple Silicon runs it emulated. Listed in `MIRROR_ARCH_EXEMPT`. **Rosetta turns out not to be required:** on 2026-08-17 it ran under Colima with `vmType: vz` and **`rosetta: false`** — 1/1, 0 restarts, `:30700` → 200, zero error lines. The cost is time: **9 min 03 s** from pod creation to Ready, against seconds for the Go Console. Say so in the module 08 text so a presenter starts it early instead of concluding it is broken. |
| module 10 scenario 3 never shows `ImagePullBackOff` — anywhere, even offline | Correct by design, and for a **deeper reason than the `skipFallback: false` fallback** everyone assumed. `cloudbox-init.sh` stores mirror content under the **registry-stripped** repo path (`ghcr.io/knative/helloworld-go` → `knative/helloworld-go`) and `create-cluster.sh` points the *docker.io* mirror at that same registry, so the poisoned `docker.io/…` ref with an identical path and digest is a **mirror HIT**. Measured 2026-08-17: `containerd/v2.2.6` requested manifest and every blob with `?ns=docker.io` and got `200` from `cloudbox-mirror`; pull time 265 ms; the traffic never left the laptop. So the pull succeeds offline too — the failure is reserved for refs the mirror does not carry, or clusters built without the pre-pull. Do not "fix" the manifest, and do not restore an `ImagePullBackOff` expectation to the check: the scenario and `verify.sh` were rewritten to assert the policy violation reaching the cluster instead (see `lab/10-day2-ops`). |
| module 10 scenario 2's poison is `2Mi`, which "cannot be a plausible rightsizing" | Deliberate and calibrated, and it replaced an `8Mi` that produced **no symptom at all**. On containerd 2.2.6 + runc, `helloworld-go` is Ready and restart-free at 4/6/8/12Mi (8Mi survived 300 sequential and 4800 concurrent requests before *one* replica OOMKilled — unusable as a lab), while ≤3Mi never starts. At `2Mi` the sandbox fails in seconds with the runtime naming the cause: `FailedCreatePodSandBox … container init was OOM-killed (memory limit too low?)`. The scenario now teaches "a limit is the budget your container is created inside", not a `lastState: OOMKilled` cadence — that signature is not reachable with this image without a load generator. Do not raise the value back toward plausible-looking numbers without re-measuring. |
| `kagent-controller` CrashLoopBackOffs ~3× right after you enable kagent | Ordering, not configuration. It runs its DB migration at startup and starts before `kagent-postgresql` has endpoints (`connect: no route to host`), then self-heals — 1/1 within ~40–90 s, app Synced/Healthy, seen in both 2026-08-17 runs. Module 10 now says so in the text and uses it as a teaching moment. Only read the logs if it is still restarting after ~3 minutes. |
| `application-xr`'s `spec.env` does nothing | Correct — it is **RESERVED, not implemented**. The Composition emits no patch for it; the field stays in the XRD so the v2 append lands without an API break. The VENDOR.md claimed for months that it was "appended"; git history shows the patch never existed. The XRD description now says so. |
| `docker.io/grafana/grafana` vanished from `images.txt` | It was only the `FROM` line in `apps/grafana/Dockerfile`, consumed by CI. No pod ever pulled it. The deployed image is `ghcr.io/randax/cloudbox-grafana`. |

## PROVEN ONCE — helm 4 on the apply path

`helm` is pinned to **4.2.4**, used by three real `helm upgrade --install` calls
(Cilium in `create-cluster.sh` and `kind-fallback.sh`, Gitea in
`bootstrap-gitops.sh`). Renders were verified identical to 3.21.3 — crossplane
and gitea byte-for-byte, cilium differing only by three empty-string ConfigMap
keys that helm 4 strips as null chart defaults, functionally inert.

**The 4.2.3 → 4.2.4 patch (2026-08-17) is not render-neutral, and the vendor
gate caught it.** 4.2.4 fixes "vanishing empty lines", which changes *how much
blank line* a chart render carries: `check-vendor-drift.sh` guard 1 went red on
`kagent.yaml` and `rustfs.yaml` with a new hunk id `0972f4d7` — two blank lines
before a `---` where 4.2.3 emitted one — and on `rustfs.yaml` it also *retired* a
curation, because 4.2.4 no longer emits the empty trailing KMS `secret.yaml`
document at all. Same hunks, more of them, on crossplane (9 → 20) and kagent
(21 → 25). All whitespace, no object changed; the allowlists were updated rather
than the manifests re-rendered, and each component's VENDOR.md says so. **The
lesson for the next helm patch: expect the render gate to move, and read the
hunks before blessing them** — a real chart change would arrive looking exactly
the same at first glance.

The untested part is **apply**, not render. helm 4 defaults `--server-side` to
`auto`, which for a *fresh* release — every workshop cluster — resolves to
server-side apply. All three invocations therefore pass **`--server-side=false`**
explicitly, keeping helm 3's proven client-side path, so this is a
same-behaviour-newer-binary bump rather than a behaviour change.

**Both real installs took the client-side path on 2026-08-17, verifiably** (on
4.2.3 — the rehearsal predates the 4.2.4 patch by hours, and nothing in 4.2.4's
notes touches the client-side path; its only server-side change is a *conflict
retry* fix that `--server-side=false` never reaches). After Cilium (module 01)
and Gitea (module 02):

    kubectl -n kube-system get ds cilium -o jsonpath='{…managedFields…}'
    manager=helm operation=Update          # server-side apply would read operation=Apply

Same for `deploy/gitea` in ns `gitea`. Both releases `deployed` at revision 1, no
field-ownership complaints, no `--force-conflicts` needed anywhere. That is
exactly what `--server-side=false` promises, so the bump is confirmed inert on
the apply path as well as the render.

**This is still the first thing to revert if module 01 or 02 misbehaves** — set
`helm = "3.21.3"` in `mise.toml` and drop the three flags. Nothing in the repo
needs a helm 4 feature.

**Retire the flags when:** a full `bootstrap-test` is green with them removed.
Nothing was odd on 2026-08-17, so there was nothing to A/B against; the flags
were left in place. On this evidence the experiment looks safe to try, but it is
a separate change, not a side effect of the rehearsal.

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

## LIVE — the Console's Case file cannot read kagent 0.9.12's stream

Module 10's second half is "open an investigation in the Console and watch the
tool-call log". Against the pinned kagent **0.9.12** that surface produces exactly
one thing: *"Investigation failed — the agent responded in a format this console
doesn't recognize. Check that your kagent version matches the workshop pin."* The
message sends the attendee after a version problem that does not exist.

**The run is fine; the translation is not.** Driven end to end on 2026-08-17 (the
Console's own endpoint, `POST /agent/ask` for `demo/Component/demo-web`, scenario 1
injected), the controller answered `200` after **87 s** and the agent really worked:
`k8s-agent` logged `POST http://host.docker.internal:11434/api/chat 200` and a tool
call to `kagent-tools`. Capturing the raw A2A stream from the controller
(`POST /api/a2a/kagent/k8s-agent/`, `message/stream`) shows why the console sees
nothing — the frame shapes kagent actually emits are:

    result.kind = "status-update"   … status.message.parts[].kind = "data",
                                      data = {name, args, id}          ← tool call
    result.kind = "status-update"   … data = {name, id, response:{content:[…]}}  ← tool result
    result.kind = "status-update"   … status.message.parts[].kind = "text"       ← narration
    result.kind = "artifact-update" … artifact.parts[].text                      ← final answer
    result.kind = "status-update", final = true                                  ← terminus

`apps/portal/internal/kagent/kagent.go`'s `translate()` accepts top-level
`kind: "message"`, `"tool-call"` and `"tool-result"` — kagent emits none of those,
so every frame is dropped, `emitted == 0`, and `agent_ask.go:233` renders the error
card. The code's own comment (`reconcile against live kagent at rehearsal — see
spec #133 rehearsal gates`) marked this exact gate; this is that reconciliation, and
it failed.

**Fix belongs in the portal** (`translate()` + `rpcResult`: read tool steps out of
`status-update.status.message.parts[].data`, narration out of its `text` parts, and
the answer out of `artifact-update`), and it needs a portal image release before it
reaches a cluster. Until then module 10's README says so and points at
`kubectl -n kagent logs deploy/k8s-agent -f`, which shows the same tool calls and the
host model request. **Retires when:** one investigation renders tool calls and a
verdict in the browser against kagent 0.9.12.

## PROVEN ONCE — the kagent inference path, and what is still unproven

The 2026-08-17 rehearsal could not exercise this at all (no `ollama` on the host, so
`cloudbox-init.sh` warned and skipped the model pull). Re-driven the same day against
the still-running cluster, with `ollama 0.32.14` installed from Homebrew and
`qwen3:4b` pulled:

- **Host reachability works, including the default loopback bind.** A pod resolved
  `host.docker.internal` → `192.168.5.2` (Colima `vmType: vz`) and got
  `{"version":"0.32.14"}` from `/api/version` with Ollama listening on
  **`127.0.0.1:11434` only** — Colima proxies it, as Docker Desktop does. No
  `OLLAMA_HOST` change needed on macOS.
- **The default ModelConfig resolves and the model answers.** `provider: Ollama`,
  `model: qwen3:4b`, `num_ctx: 64000`, unchanged from the chart: `k8s-agent` logged
  `POST http://host.docker.internal:11434/api/chat 200`.
- **Beat 1 flails exactly as the module claims.** One real tool call
  (`k8s_describe_resource`, which returned), then a *printed* `<function-call>` block
  naming a pod that does not exist, then the symptom restated as a cause. No second
  tool call. 87 s wall clock.
- **The model switch beat 2 teaches is real and fast.** One field pushed to Gitea
  reached `modelconfig/default-model-config` in **20 s**; kagent rolled a new
  `k8s-agent` pod; the newly named model loaded in Ollama and answered
  (`POST /api/chat 200`, 25 s). Proven by switching between two *local* models.
- **The honest-spec line now has a number.** `qwen3:4b` at the chart's
  `num_ctx: 64000` costs **~11.5 GiB** on the host — 2.4 GiB weights, **9 GiB KV
  cache** — measured from Ollama's own memory breakdown. The context window, not the
  4B of weights, is what does not fit beside a 16 GiB Colima VM. A 7–8B model at the
  same context asked for 7.8 GiB and Ollama evicted the previous model to get it
  (`system_free 3.3 GiB, system_limited=true`).

**WATCH — the residue, in the order it would bite:**

1. **The Console surface is broken** (previous entry). Everything above was driven
   through logs and the raw A2A stream, not the browser.
2. **Beat 2's actual provider is untested.** No OpenCode Zen key existed, so
   `provider: OpenAI` + `baseUrl: https://opencode.ai/zen/v1` + `apiKeySecret` has
   never been exercised — nor has the Anthropic fallback. The *switch* is proven; the
   *endpoint, secret plumbing and auth* are not. Zen's free tier is also explicitly
   time-boxed and may simply be gone.
3. **Native Linux is unproven twice over:** the `10.5.0.1` ModelConfig edit, and the
   fact that a loopback-bound Ollama cannot be reached across a plain bridge (module
   10's README now says to use `OLLAMA_HOST=0.0.0.0` there — untested).
4. **The "16 GB does not fit" claim is still a claim.** It was measured on a 32 GB
   Mac; the 11.5 GiB figure supports it arithmetically, nothing has run it on a
   16 GB machine.
5. **`cloudbox-init.sh` skips the model pull silently-ish** if Ollama is not
   installed *yet* when module 00 runs — which is the likely order for an attendee
   who installs it after reading module 10. The README now says to check
   `ollama list`.

**Retires when:** one investigation renders in the browser, and one beat-2 run
against a hosted provider returns a verdict.

## PROVEN ONCE — smaller things the rehearsal settled

| What | What 2026-08-17 measured |
|---|---|
| **NATS 2.14 liveness** | Ready **2/2 in 25 s**, 0 restarts, `/healthz` and `/healthz?js-enabled-only=true` both `{"status":"ok"}`, JetStream up, PVC Bound. **And the premise was wrong:** `local-path` is a hostPath bind that does not enforce the 1Gi request — inside the pod `/data` reports the node's whole 97.9 G — so "a full PVC CrashLoops the pod" needs the *node* disk to fill, not the PVC. Much less reachable than feared, and also: nothing bounds JetStream's growth. |
| **BuildKit v0.32.2, module 07** | `moby/buildkit:v0.32.2-rootless` came up **2/2 in 15 s** and the workflow reached `Succeeded` inside the 91 s solve, on kernel 6.8.0-117 arm64 / containerd 2.2.6, PSA-privileged `builds` namespace. No runc or rootlesskit trouble at all. |
| **zot v2.1.20 under chart 0.1.122** | Tag override in effect (`:v2.1.20` over the chart's declared v2.1.18), 1/1 in 16 s. **Anonymous push works** — `crane copy --insecure` with no credentials — and `:30500` answered 200 on `/v2/`, `/` (UI extension) and `/v2/_zot/ext/search` (GraphQL). One non-finding: `/v2/_zot/ext/discover` **404s** at 2.1.20; that endpoint does not exist there, the extensions are plainly enabled. |
| **Grafana Explore deep-link** | **This was not an unproven nicety — it was broken.** Anonymous Viewer does not carry the `datasources:explore` RBAC action (26 actions, without it), so Grafana answered every `/explore…` request with `302 → /?redirectTo=…` and, since an anonymous session never logs in, **discarded the `panes` payload entirely**: every Console deep-link landed on the Grafana home page. `/` and `/dashboards` returning 200 is what made it easy to miss. Fixed in `d608d88` with `GF_USERS_VIEWERS_CAN_EDIT=true` (marked load-bearing in the component's VENDOR.md) and verified served: bare `/explore` **200**, deep-link **200**, `datasources:explore` granted, `dashboards:write` still denied (27 actions), the `panes` JSON parses, its uids resolve, and both carried expressions return data through the proxy (`sum(k8s_pod_cpu_usage{k8s_namespace_name="observability"})` → 0.0623, `sum(cnpg_backends_total{cnpg_cluster="my-db-pg"})` → 1). **Still one human click from "renders prefilled"** — the rehearsal had no browser. (`GF_AUTH_ANONYMOUS_ORG_ROLE=Editor` is the one-line alternative; it grants more than Explore.) |
| **OTel 0.158.0 deprecation WARNs** | **The count was wrong: 4 on the agent, not 3.** Gateway is 5 as predicted (`otlphttp` ×3, `spanmetrics`, `servicegraph`); the agent emits `otlphttp` ×2, `kubeletstats` **and `filelog`**, identically on both DaemonSet pods — so **13 cluster-wide**, once at startup each. Legacy IDs stay on purpose: renaming makes the config unloadable on 0.149.0, breaking rollback. Pre-empt the corrected count in the module 09 text. |
| **Module 09 trace waterfall** | **One connected trace: 37 spans, exactly 1 root, 0 spans with a missing parent** — `cloudbox-portal POST /gallery/upload` → activator → uploader → `s3 put original` → `broker.ingress` → in-memory channel → `broker.filter` → activator → resizer → `s3 download` / `decode and resize` / `s3 upload thumbnail and meta`. It does not fragment: the re-applied `config-observability` keys (nine in serving, six in eventing — the curation the VENDOR.md audit found missing) are what buys this. VictoriaTraces knew all 10 services. Whole observability stack Synced/Healthy in ~90 s. |

**Louder than any of those 13 one-shot WARNs, and unresolved:** the OTel gateway
logs a **failed Prometheus scrape every 30 s, forever**.
`net-kourier-controller` ships the `prometheus.io/scrape` annotations and
declares port 9090, but Knative 1.23 moved its metrics to the OTel pipeline and
opens nothing there — so `connection refused`, one target, one WARN per interval.
Harmless, permanent, and the only *recurring* error-shaped line in the stack.
Silencing it needs either a curation dropping the upstream annotation or a drop
rule in the receiver; both are curation decisions nobody has taken.

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

## RESOLVED — the AWS CLI is gone; s5cmd does the S3 work

**Decided and shipped 2026-08-17.** `public.ecr.aws/aws-cli/aws-cli:2.36.24` was
used by modules 03, 04 and 09 and by the platform-api / application-xr bucket
Jobs, with **no rationale recorded anywhere**. The choice was between writing the
rationale down and changing the tool; the tool changed, to
**`docker.io/peakcom/s5cmd:v2.3.0`**.

**The deciding reason was honesty, not size.** A sharp attendee asks "why am I
typing `aws` in a workshop about *not* using AWS?", and the only true answer was
"nobody wrote it down". The lesson the call sites exist to teach is *RustFS
speaks the S3 API, so standard S3 tooling works against it unchanged* — and a
vendor-neutral client makes that point better than the vendor's own CLI, which
invites exactly the wrong inference. The labs now say so where an attendee reads
it (module 03 hint 4, module 09 hint 3), and module 09 names the third client in
the same story: the uploader and resizer talk to the same bucket with
`minio/minio-go`. Three clients, one API, indistinguishable to the server.

The size was the tiebreak, and it is not small: **12 MiB compressed on arm64
against 129 MiB** (`crane manifest … | jq '[.layers[].size]|add'`), on a
component every attendee pre-pulls. `rclone` (~30 MiB) lost because it needs its
own `RCLONE_CONFIG_*` idiom; s5cmd reads the **same** `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` / `AWS_REGION` and takes `--endpoint-url`, so every
credential block in the Jobs and compositions carried over byte-for-byte. `mc`
was never in the running — MinIO's community edition being discontinued is the
reason RustFS is here at all.

**Two things that were expected to be hard and were not.** They are recorded
because the *next* person to touch this will assume the same things:

- **The image is not FROM scratch.** It is `alpine-minirootfs-3.20.3` + the
  single binary (3 layers, `crane config … | jq .history`), so `/bin/sh` →
  busybox 1.36.1 is present and `command: ["/bin/sh","-c"]` works exactly as it
  did with the AWS CLI. There was no need for two containers, sequential
  commands, or s5cmd's `run` subcommand. **What *is* different: `ENTRYPOINT` is
  `/s5cmd`**, so `command:` must override it, `PATH` does not contain `/`, and
  the binary must be called by absolute path `/s5cmd`.
- **`mb` on an existing bucket exits 0** against RustFS 1.0.0-rc.2, printing
  `mb s3://<bucket>` and, with `--json`, `{"operation":"mb","success":true,…}`.
  So the feared hot-loop (a `restartPolicy: OnFailure` Job retrying a non-zero
  `mb` forever) does not exist here. **The guard was kept anyway**, as
  `s5cmd ls s3://<bucket> >/dev/null 2>&1 || s5cmd mb s3://<bucket>` — because
  that exit 0 is the *store's* `CreateBucket` behaviour, not a promise from
  s5cmd, and RustFS is a prerelease. `ls` on a bucket is a faithful
  `s3api head-bucket`: exit 0 when it exists even if empty, exit 1 +
  `NoSuchBucket` (404) when it does not.

**The one real trap the swap exposed, and it was pre-existing.**
`kubectl run --rm -i --restart=Never` folds the container's **stderr into
kubectl's own stdout** when the container exits before the attach lands — which
a 22 MB Go binary always does, and a Python CLI that takes a second to boot
never did. So `2>/dev/null` on the kubectl side stopped suppressing the client's
error text, and a naive port of module 03's "is the listing non-empty?" check
would have read `ERROR "ls s3://app-assets": NoSuchBucket…` as *objects*, i.e. a
**false pass in a graded check**. Reproduced 5/5. The fix is to stop reading
stream separation as a signal:

- **existence** comes from the **exit code**, which is unaffected (verified 5/5:
  exit 1 for a missing bucket, 0 for an existing one, including an empty one);
- **content** comes from stdout with s5cmd's own `ERROR ` lines filtered out.

`lab/09-capstone/verify.sh` gets this for free, because the reshaped
`list-objects-v2` equivalent —
`s5cmd ls --show-fullpath "s3://images/<prefix>" | sed -n 's|^s3://images/||p'` —
uses `sed -n …p`, which only prints lines that matched and therefore drops the
ERROR line without a second filter. That reshape was needed regardless: plain
`s5cmd ls` prints `date size basename` **relative to the prefix**, so
`--show-fullpath` is what makes it emit keys. Its output is byte-identical to
what `aws s3api list-objects-v2 --query 'Contents[].Key' --output text` produced,
compared directly on the live cluster. Note also that an empty prefix exits **1**
with `no object found`, so those call sites keep an explicit `|| true` under
`set -euo pipefail`.

`presign` translates as `presign --expire 1h` (aws: `--expires-in 3600`);
s5cmd's default is 3h.

**Residue worth knowing, none of it blocking:**

- s5cmd lives on **Docker Hub** (`peakcom` org; there is no GHCR mirror — a
  `ghcr.io/peak/s5cmd` pull is DENIED). At the venue that is irrelevant, because
  `docker.io` is in the mirror map and `cloudbox-init.sh` pre-pulls it. On a
  CI runner it is one more anonymous Docker Hub pull, on shared GitHub IPs.
- The `command -v aws` fast paths became `command -v s5cmd`, which flips which
  branch CI takes: `ubuntu-latest` ships the AWS CLI, so the *local* branch used
  to run there and the in-cluster pod branch now does. That is the branch
  attendees take, so it is better coverage — but it is slower (one pod per call,
  and module 09's `solve.sh` polls in a loop), and it was not the branch CI
  exercised before. Watch `bootstrap-test.yaml`'s module 09 timing.
- **s5cmd was deliberately not added to `mise.toml`.** It would make the "run it
  on your laptop" variant work for everybody, but it would put the version in a
  second place with nothing comparing the two (`check-consistency.sh` only knows
  the pairs it is told about). If someone wants it, add the pin *and* the
  assertion, in its own PR.

## Minor — `check-upstream.sh` prerelease-word gap

The semver comparison treats an unknown suffix as a build *flavor*
(`-rootless`, `-alpine`), which is correct and cannot under-report drift — this
was tested across all 49 suffix/version combinations the repo uses. But a suffix
that is *semantically* a prerelease and not in the known word list
(`-m1`, `-milestone2`, `-devel`, `-eap`) would be read as release-grade and
could under-report. **No pin here uses one.** Fix the word list if one ever
appears; do not "fix" the flavor-stripping.
