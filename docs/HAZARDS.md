# Known hazards

Everything we know is dangerous, deliberately weird, or unproven — with what
would go wrong, how you would notice, and what retires it.

Written during the pre-event bump pass on **2026-08-11**, three weeks before the
workshop (JavaZone, Sept 2–3), and rewritten after **two** full end-to-end
rehearsals, both on **2026-08-17** and both on the same Apple Silicon laptop
(Colima, 8 CPU / ~16 GiB, Talos v1.13.8 / Kubernetes v1.36.2 / containerd 2.2.6):

- **Rehearsal 1** (morning, warm mirror, one cluster): modules 00→10, **11/11
  `verify.sh` exit 0**, 21/21 ArgoCD Applications Synced+Healthy, **~16 minutes of
  script time** against the 240-minute budget. It found three blockers, two of which
  no CI job we have can see — and it ended on a cluster whose node CPU caps had been
  raised by hand after the module 10 end state wedged.
- **Rehearsal 2** (evening, **cold start** — cluster *and* mirror destroyed first, the
  full 7.25 GB pre-pull re-run from nothing): modules 00→10 again, **11/11
  `verify.sh` exit 0 on two clusters**, the second one built by
  `catch-up.sh 10 --rebuild` — the recovery path — and **~32 minutes of script time**,
  still against 240. It found four more bugs — one of them a blocker, and again in the
  place CI cannot look — all four fixed the same evening (`1f12353`, `ca4859e`,
  `92aac7a`, `4e2817b`).

The extra ~16 minutes is coverage, not regression: s5cmd's in-cluster pod branch
(+1:30 module 03, +1:09 module 04, +1:47 module 09), deliberately longer settle
windows in module 05, and a module 10 whose scenarios 2 and 3 now produce real
symptoms and whose agent investigation actually runs. The machine is still not the
constraint. `docs/MAINTENANCE.md` is how pins get bumped; this is what to be afraid
of while doing it.

Both runs landed on the same calendar day, so **"rehearsal 1" and "rehearsal 2" are
used below** rather than the date, wherever it matters which one a number came from.

Status key: **LIVE** = a real risk today · **WATCH** = unproven, needs a
rehearsal to settle · **PROVEN ONCE** = came out green in a 2026-08-17
rehearsal, on one machine, one architecture — settled, not proven ·
**RESOLVED** = was a real hazard, is fixed, and the entry is kept because the next
person needs the history ·
**TRAP** = looks like a bug, is deliberate, do not "fix"

---

## RESOLVED — node containers were capped at 2.0 CPUs, whatever the laptop had

**Fixed in `33c84f7`; proven decisively in rehearsal 2.** Kept in full, because the
before/after *is* the evidence and because the residual at the bottom is live.

`talosctl cluster create docker` defaults **`--cpus-controlplanes` and
`--cpus-workers` to `2.0`** (its own `--help` says so), and
`scripts/create-cluster.sh` passed neither — it raised `--memory-controlplanes` /
`--memory-workers` deliberately and said nothing about CPU. So the entire
Kubernetes cluster ran inside a **4-CPU budget** no matter how many cores the
machine had:

    docker inspect cloudbox-worker-1 --format '{{.HostConfig.NanoCpus}}'
    2000000000                                     # = 2.0 CPUs

It was even in `talosctl`'s own creation summary (`CPU 2.00` per node), where
nobody reads it as a limit.

**What it did.** Everything schedules onto the one untainted worker. Modules
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

**You could not rescue it afterwards.** `docker update --cpus 3` /
`--cpus 4` on the live containers dropped pressure 98.7 → ~92 but the cluster did
**not** come back within the next ~10 minutes; once kubelet is behind on ~125
containers the backlog outlives the fix, and draining it took ~20–30 minutes. The
caps have to be right *before* the load arrives — which is why this had to be fixed
in `create-cluster.sh` and not documented as a workaround.

**The fix is to cap nothing at all.** `create-cluster.sh` now reads the Docker
daemon's core count (`docker info -f '{{.NCPU}}'`), floors it at talosctl's own
`2.0` (`TALOS_CPU_FLOOR` in `versions.env`, so a minimum-spec machine is never worse
off than before) and passes it to **both** containers. That is deliberately
oversubscribed: a `--cpus` value equal to the host count is not a meaningful quota,
which is the point. Same rule we apply to our own workloads — requests schedule, a
CPU limit throttles rather than queues.

**Rehearsal 2, cold cluster, same laptop, same module 10 end state:**

    $ docker inspect cloudbox-{controlplane,worker}-1 --format '{{.HostConfig.NanoCpus}}'
    8000000000        # 8.0 CPUs each, was 2000000000 — and CpuQuota=0 CpuPeriod=0

| at module 10's end state | rehearsal 1 (2.0 CPUs/node) | rehearsal 2 (8.0 CPUs/node) |
|---|---|---|
| `/proc/pressure/cpu some avg10` | **98.72** (avg300 96.02) | **1.08** (avg300 2.97) |
| memory pressure | 0.00 | 0.00 (avg300 0.24), 7.7 GB available |
| worker node | `NotReady`, kubelet `HEALTH Fail` | `Ready`, kubelet `HEALTH OK` |
| `kubectl` | `TLS handshake timeout` for tens of minutes | instant |
| Kourier gateway | `ContainerCreating` ~11 min | 1/1 in seconds, 0 restarts |
| Backstage to Ready | **9 min 03 s** | **0 min 57 s** |
| apps / pods | wedged before reaching 21 | **21/21 Synced+Healthy, 73 pods** |

**~90× less CPU pressure, and no wedge** — and everything downstream got better at
the same time, which is the signature of one real bottleneck rather than a pile of
separate problems. Backstage's nine minutes was never the amd64 emulation; it was
the cap. Note also that rehearsal 1's hand-repaired cluster (3 CP / 4 worker, set
with `docker update` after the wedge) idled at `some avg10=1.30` with the same 21
apps, against the uncapped run's 1.08 under load: what mattered was removing the
quota, not the exact number.

**The residual, recorded honestly: we removed a throttle and put no bound in its
place.** Each node still advertises the **whole VM** to the scheduler, because
kubelet inside a Talos-in-Docker node reads the host's `/proc`, not its cgroup:

    $ kubectl get nodes -o custom-columns='NAME:…,CPU:.status.capacity.cpu,MEM:.status.capacity.memory'
    cloudbox-controlplane-1   8   16340372Ki
    cloudbox-worker-1         8   16340372Ki
    # → the scheduler believes it has 16 CPU / 32 GiB, on an 8 CPU / 16 GiB VM

Nothing stops a genuinely oversubscribed cluster. Option (3) from the original
entry — give the observability stack real resource requests, so the scheduler
refuses instead of thrashing — is still unimplemented and is still the right belt to
go with these braces. On 8 cores it does not bite; the next entry is where it might.

## LIVE — `MIN_CPUS="4"` is now under-specified rather than wrong

Both rehearsals ran on an **8-CPU** host. `MIN_CPUS="4"` is a published promise
(principle 12, honest specs) and `install.sh --check` enforces it, but what has
actually been measured at the module 10 end state — 21 apps, 73 pods — is 8 cores,
twice, and nothing else.

Uncapping helps a 4-core laptop rather than hurting it: with `TALOS_CPU_FLOOR="2"`
and a 4-CPU daemon, both node containers now get **4/4 where they previously got
2/2** — strictly more than any attendee has ever had. But "better than before" is
not "measured", and the residual above means the scheduler on such a machine will
happily over-commit two nodes that each claim 4 CPUs.

One piece of evidence does exist and is worth naming precisely: `bootstrap-test.yaml`
runs on a **4 vCPU / 16 GB** `ubuntu-latest` runner and the repo's own header claims
the core path (01–07) green there. So what is untested at 4 cores is not the workshop —
it is specifically the **stretch end state**, modules 08–10, the 21 apps and 73 pods
that wedged an 8-core machine when it was throttled to 4.

**Unresolved — a maintainer decision, not a patch.** Options, in the order worth
considering: (1) keep `MIN_CPUS="4"` as the **core-path (00–05)** gate, which is
what `versions.env`'s comment now says it is, and state in modules 06–10's
prerequisites that the full stack wants ≥8 cores; (2) raise the minimum for the
stretch path and say so in the published matrix; (3) implement the resource
requests, the only option that makes a 4-core machine degrade instead of thrash;
(4) measure it — one `catch-up.sh 10` on a 4-CPU Docker daemon would settle the
whole question in twenty minutes. `install.sh --check` verifies the *host* core
count, which since the fix is also what the cluster gets, so it no longer understates
the truth — it just cannot tell a 4-core machine that modules 08–10 are untested
on it.

## TRAP — a green `bootstrap-test.yaml` means "the workshop works on Linux"

`bootstrap-test.yaml` runs on `ubuntu-latest`, where the host routes straight
into the Talos docker network. **macOS, Windows, and every Docker
Desktop / OrbStack / Colima host does not** — and macOS is a fully supported
platform in the published matrix (`docs/PRINCIPLES.md` §12) on which most of a
JavaZone room will be sitting.

**Two rehearsals have now *each* found a workshop-stopping bug that CI cannot see,
and both were in the recovery path** — the second cluster of the day, and
`catch-up.sh`. Say it plainly, because it is the strongest generalisation this
project has earned: a CI runner creates exactly one cluster, runs the labs forward
once, and is then discarded, so the *entire* "something went wrong, get me back on
track" surface is untested **by construction**. That is also the surface reserved for
people who are already in trouble.

**Rehearsal 1 — the two blockers CI could not see:**

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
  `--request-timeout=5s` so the timeout matches its message. **Rehearsal 2 ran it
  cold and unattended and it holds: 2:09 on the first attempt, nodes Ready at 52 s
  of age, kubeconfig at `https://127.0.0.1:54854` with `10.5.0.2:6443` nowhere in
  it, and the retry loop never even engaged because the API was already up.** But
  rehearsal 2 also found the blocker still armed elsewhere — see below.
- **`destroy && create` failed on the second cluster of the day** (fixed
  `3a7848f`). `talosctl config remove` **refuses to remove the currently-selected
  context and still exits 0** ("skipping removal of current context …"), and
  `destroy-cluster.sh` discarded its output — so the context was never removed,
  the next `talosctl cluster create` found the name taken and renamed **the new**
  context to `cloudbox-1`, and every `talosctl --context cloudbox` in
  `create-cluster.sh` then dialled the destroyed cluster (`connection refused`,
  exit 1, before Cilium). This broke `catch-up.sh --rebuild`. **Proven fixed in
  rehearsal 2, on the very run where it used to appear:** `✅ talosconfig context
  removed` is now true, `talosctl config contexts` afterwards shows exactly one
  `cloudbox` pointing at the *new* cluster's port, there is no `cloudbox-1` rename
  and no `connection refused`, and the second `create-cluster.sh` of the day got all
  the way past Cilium.

**Rehearsal 2 — one more blocker, same blind spot:**

- **`catch-up.sh` deadlocked against itself on modules 07–10** (fixed `92aac7a`).
  Step 5 blocked until **every** Application listed in `solutions/module-N/apps/`
  was Synced+Healthy, and only then (step 6) ran `post.sh`. From module 07 on that
  list includes `demo`, whose `hello-site` Deployment references
  `localhost:30500/hello-site:v1` — an image that exists **only after `post.sh` runs
  the in-cluster build**. On a fresh cluster zot is empty, so `demo` sat in
  `ImagePullBackOff`, the gate died at ten minutes (`❌ Application 'demo' is still
  'Synced Degraded' after 10 minutes`), and the step that would have produced the
  image never ran. Re-running did not help — the second run hits the same gate.
  Affected `catch-up.sh` 07, 08, 09 and 10, with and without `--rebuild`.
  `solutions/module-07/post.sh`'s own header comment already described the symptom
  ("hello-site deployment stays in ImagePullBackOff until the workflow has pushed
  the image"); only the ordering never accounted for it. Fixed by depending on the
  *platform* components instead: wait for the platform apps → run the post-steps →
  then wait for `demo`, which is what the post-steps produce. `catch-up.sh 10` then
  exited 0 in **4:13** on a twenty-minute-old cluster and an eleven-module
  `verify.sh` sweep on it came back **11/11 exit 0**. **No CI job runs
  `catch-up.sh` at all** — and neither did rehearsal 1.
- **Green CI is not evidence about *timing*, either** (fixed `ca4859e`).
  `wait_for_cr`'s `kubectl wait --for=condition=Established crd/$name` on a CRD that
  does not exist yet does not wait — `kubectl wait` on a **named** object returns
  `Error from server (NotFound)` immediately, which under `set -euo pipefail` kills
  the caller. It killed `lab/06-serverless/solve.sh` outright, before the ksvc or the
  cold-start curl. The trigger is structural, not bad luck: `wait_app` deliberately
  returns on **Healthy alone** (requiring Synced was a recurring flake), so an
  Application can legitimately still be `OutOfSync` with its CRDs unapplied at the
  moment `wait_for_cr` runs, and the wider the sync wave the likelier it is.
  `wait_for_cr` is used by modules 03, 04 and 06. CI runs every `solve.sh` and had
  never hit it. Fixed by polling `kubectl get crd/$crd` into existence (60 × 5 s)
  *before* waiting on `Established`.

**The standing lesson, now twice-earned: rehearse on a Mac before the event, and
specifically rehearse the *recovery* — the second cluster and `catch-up.sh <n>` —
not just the forward path.**

**Half of that is now automated** (`ae224f4`): `bootstrap-test.yaml` grew a
`recovery-path` job that creates a cluster, runs the real attendee command
`catch-up.sh 07 --rebuild`, and destroys it again — asserting exactly one selected
`cloudbox` context with no `cloudbox-N` rename, that `create-cluster.sh` never had to
print its stale-context self-heal warning (which would otherwise *mask* a
`destroy-cluster.sh` regression), that a final destroy of a live cluster leaves zero
contexts and zero node containers, and that `hello-site` rolled out with `demo`
Synced/Healthy — i.e. the post.sh-before-demo ordering, asserted at the end state.
Module 07 because the deadlock lived there and it needs no first-party images.

**The other half is still open: there is no macOS job.** Both of rehearsal 1's
blockers were macOS-shaped, the `recovery-path` job runs on `ubuntu-latest` like
everything else, and the platform most of the room will be on is still covered only by
a human rehearsing before the event. Green CI is now evidence about Linux, forwards
*and* backwards — and nothing else.

## RESOLVED — the workshop scripts ran against whatever cluster `kubectl` pointed at

**Found in rehearsal 3, closed in `2b8de71` (lab/) and `b4f5e2d` (scripts/ +
solutions/).** Kept in full: the near-miss is the evidence, and the residual at the
bottom is live.

`destroy-cluster.sh` removes the `admin@cloudbox` kubeconfig entries. `kubectl` then
falls through to the next entry in the same `~/.kube/config` — and this audience
arrives with a dozen. On the ordinary attendee path, `lab/01-cluster/verify.sh`
printed

    ✅ kubectl reaches the API server
    ❌ FAIL: want 2 Ready nodes, have 36/36

against a real **36-node corporate cluster** at `https://172.16.4.2`. `verify.sh`
only reads, so nothing was harmed. Nothing else on the list only reads.

**The second commit is the one that mattered.** The first guarded 18 lab scripts and
left `scripts/` alone, where the exposure is worse: `bootstrap-gitops.sh` makes 13
`kubectl` calls and installs Gitea **and** ArgoCD, `seed-gitea.sh` force-pushes the
platform repo and applies the root app-of-apps, `catch-up.sh` and the
`solutions/module-*/post.sh` it invokes rewrite the platform. The same fall-through
would have installed **a complete GitOps control plane into an employer's cluster**.

**It refuses rather than warns, and has no environment override** — the outcome it
prevents is applying workshop manifests to someone's employer's cluster, and an
override is precisely the line that gets copy-pasted past a safety check by someone
in a hurry in a conference room. It asserts the context **name** *and* the **API
server address**, because neither is sufficient: a name is one `rename-context` from
wrong, and minikube, k3d and Docker Desktop are all on loopback too. Both cases were
proven with fixtures — a context *named* `admin@cloudbox` pointing at a remote server,
and a legitimate local `minikube`. It reads the kubeconfig only and makes no API
call, so a merely stopped workshop cluster still passes and module 01 keeps its own
"kubectl cannot reach the cluster" diagnosis.

**Three placement facts, each enforced by `check-consistency.sh` rather than
remembered:**

- **It cannot fire on source in `scripts/lib.sh`.** `create-cluster.sh` and
  `kind-fallback.sh` source lib.sh and legitimately run *before* any workshop context
  exists — they create it. lib.sh only *defines* the guard; check 8 fails if it ever
  calls it.
- **`catch-up.sh` guards AFTER its `--rebuild` branch.** In front of it, the one
  command reserved for people already in trouble would refuse on the very cluster it
  is about to replace. Check 8 compares the line numbers.
- **`destroy-cluster.sh` is deliberately NOT guarded** — it is what *causes* the
  fall-through, so it must work when the context is already wrong. Safe only because
  nothing in it resolves through the current context: `talosctl cluster destroy
  --name` is scoped by container label, and its `kubectl` calls edit *named*
  kubeconfig entries. Check 8 asserts that premise, so the exemption cannot quietly
  grow a real cluster call.

**One copy of the guard, in `scripts/context-guard.sh`,** shared by `scripts/lib.sh`
and `lab/common.sh`. Folding it into lib.sh was tried and rejected on evidence:
lib.sh defines `ok()`/`fail()`, and `lab/01-cluster/verify.sh` defines its own
*counting* `fail()` **before** sourcing `common.sh` — lib.sh's version would have
clobbered it and module 01 would print `❌ FAIL:` lines while exiting 0.

**The residual: CI still cannot see any of this.** A runner's kubeconfig holds exactly
one cluster, so no job can distinguish a guard that works from one that is never
reached. What is proven is static (checks 7 and 8, nine planted violations shown to
fail) and manual (fixture kubeconfigs driven through `--kubeconfig`: every guarded
script exits 1 before acting, on a foreign context, on a workshop-named context aimed
elsewhere, and on no context at all). **Nobody has reproduced rehearsal 3's actual
sequence since the fix** — `destroy-cluster.sh`, then a lab script, on a laptop with a
real multi-context kubeconfig. That is a ten-minute check and the only evidence that
would retire this entry rather than settle it.

## TRAP — a `KUBECONFIG=` prefix does nothing to a mise-shimmed `kubectl`

Not a repo hazard — a maintainer-machine one, recorded because it cost real time and
mutated a live kubeconfig. `~/.config/mise/config.toml` sets
`[env] KUBECONFIG = "{{env.HOME}}/.kube/config"`, which mise applies to **every
shim** — so `KUBECONFIG=/tmp/foo kubectl …` silently uses the real `~/.kube/config`,
including `kubectl config` subcommands, which then *mutate* it. An agent renamed the
maintainer's live workshop context this way. Use `kubectl --kubeconfig=<file>`
exclusively for fixture work: the flag outranks the env var, which is what makes it
safe. Nothing in the workshop depends on `KUBECONFIG`, so attendees are unaffected.

## RESOLVED — a re-injected module 05 fault could leave nothing wrong, and `verify.sh` called it fixed

**Found in rehearsal 2, fixed in `4e2817b`.** Kept because it is the most instructive
failure either rehearsal produced: *a confident wrong answer, produced by the tooling
of the module that exists to teach people not to trust confident wrong answers.*

Sequence: `inject 1-4` → `restore.sh all` → `inject 1-4` again → wait 2.5 min →
`verify.sh` reports

    ✅ fault 01 fixed: deploy/web is Available
    ✅ fault 02 fixed: cluster/orders-db is Ready

while the namespace actually contains the restored pod still serving alongside a
second pod parked in `ImagePullBackOff` forever. Re-applying `issue.yaml` over an
already-restored namespace is accepted and changes nothing, because the state each
fault corrupts is fixed once the object exists:

- **fault 01** is a rolling update to a broken image on a **1-replica** Deployment;
  the default `maxUnavailable: 25%` rounds to 0, so the healthy old ReplicaSet pod is
  never torn down and the Deployment stays `Available` — which is exactly what
  `verify.sh` checks;
- **fault 02** applies a bad `storageClassName`, but `orders-db` already exists with a
  Bound PVC, so CNPG never re-provisions. Its own `fix.sh` **deletes and recreates**
  the cluster: the restore is destructive and the inject is not, and that asymmetry
  *is* the bug;
- faults 03 (CiliumNetworkPolicy) and 04 (mislabelled pod behind the Service) are
  immune — their fault object takes effect on apply regardless of prior state.

So the attendee debugs a cluster with nothing wrong with it, and the module is
explicitly designed to be attempted, abandoned and retried (`inject.sh`'s own closing
line is `Give up / done: ./restore.sh 1`). The **second** attempt is the one that
silently does nothing. It also meant `solve.sh` — the CI regression contract
(inject → verify must fail → restore → verify must pass) — only asserted anything on a
first run against a clean cluster.

**Fixed by refusing the ambiguity:** `inject.sh` now rejects a namespace that already
exists and names the cure, `./restore.sh clean`, which already existed and does
exactly this (verified: after `clean`, all four faults inject correctly, 4/4 caught).
The lesson generalises past module 05 — **an idempotent-looking `kubectl apply` is not
an idempotent *fault*, and a check that looks for a symptom cannot tell "fixed" from
"never injected".**

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
bench; the last two rows are live clusters, one rehearsal each:

| image | `log_level` | store | idle stdout | longest line |
|---|---|---|---|---|
| `1.0.0-beta.8` | `info` | ~240 objects | 3.26 MiB/h | ~9 KB |
| `1.0.0-rc.1` | `info` | ~240 objects | **30,030 MiB/h** *(orig. pass)* | 332,800 B |
| `1.0.0-rc.1` | `info` | 240 objects | **7,668 MiB/h** *(re-measure)* | 326,600 B |
| `1.0.0-rc.1` | `info,…scanner_io=warn` | 240 objects | 7.35 MiB/h | 3,921 B |
| **`1.0.0-rc.2`** | **`info`** ← shipped | **240 objects** | **5.45 MiB/h** | **4,157 B** |
| `1.0.0-rc.2` | `info,…scanner_io=warn` | 240 objects | 6.37 MiB/h | 4,086 B |
| `1.0.0-rc.2` | `info` | **empty** | 1.21 MiB/h | 4,068 B |
| **`1.0.0-rc.2`** | **`info`** | **on cluster, 247 objects (reh. 1)** | **3.44 MiB/h** | **4,158 B** |
| **`1.0.0-rc.2`** | **`info`** | **on cluster, 244 objects (reh. 2)** | **2.61 MiB/h** | **4,158 B** |

On rc.2 the workaround measures *worse* than no workaround (6.37 vs 5.45 —
noise): it has nothing left to suppress, which is why it went rather than
being kept "just in case".

Those two cluster rows are the measurement this entry existed to demand, taken after
modules 03/04/09 had put objects in the store, same
pod, **0 restarts**, ~2 h old both times. Rehearsal 1: 247 objects (241 in
`app-assets`, 6 in `images` from the capstone), 60 minutes, **3.44 MiB/hour**.
Rehearsal 2, independently, on a **cold-built** cluster and mirror: 244 objects,
**31.6 minutes**, **2.61 MiB/hour** — and a longest line of **4,158 B, the same byte
both times**, against the bench's recorded 4,157 B. The #5927 shape (332,800-byte
lines) is gone: the biggest line in half an hour is 4 KB. `rustfs_scanner::scanner_io`
is still the chattiest scanner target — **504 lines/hour against rehearsal 1's 502** —
so the EnvFilter directive would still have something to bite on if it regressed. Over
a 240-minute workshop this is ~10–14 MiB of container log.

**Two measurement traps, and the first one has now been reproduced twice — keep this
prominent. Window length matters as much as seeding.** Rehearsal 1: with 247 objects
present, a 300-second window read **0.06 MiB/hour**; 30 min → 2.98, 60 min → 3.44;
during the 240-object upload burst, 27.8 MiB/h. Rehearsal 2 reproduced it from the
other direction — a 300-second sub-window *inside* the 31.6-minute measurement read
**0.17 MiB/hour, 15× below the true rate**. The scanner runs on a cadence, so a
short window lands between passes and reads clean. Measure for half an hour, not five
minutes.

**And take the rate from `kubectl logs --since=<window>`, never from a difference of
two totals.** Rehearsal 2's naive byte delta came out **negative** — −3.09 MiB/h, with
the raw log *shrinking* from 3,144,405 B to 1,443,574 B across the window — because
kubelet rotation discarded the `replication_pool` boot burst (below) mid-measurement.
A rate computed from two `wc -c` snapshots is measuring rotation, not logging.

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
through 240 uploads and 120 s of idle. Rehearsal 1 reproduced it on-cluster —
**6 lines over 100 KB, longest 1,556,132 B, ~6.7 MB in the first seconds** — and
confirmed it does not scale: over the following hour of real traffic no line ever
exceeded 4,417 B. kubelet rotation then discards the burst, so `kubectl logs`
reads 556 bytes a minute later. Worth re-checking only if it ever starts scaling
with operations.

## LIVE — RustFS is a prerelease, by choice

`1.0.0-rc.2` is an rc, on a component modules 03, 04 and 09 depend on. Chosen
deliberately by the maintainer with the above evidence in hand. RustFS is beta
by design in this workshop (`docs/RESEARCH.md` §2); SeaweedFS is Plan B. It held
up in **both** 2026-08-17 rehearsals — modules 03, 04 and 09 green each time and on
both of rehearsal 2's clusters, the same pod alive 2h+ with **0 restarts**,
presigned URLs and the capstone's thumbnail path working, `mb` on an existing bucket
still exiting 0 and `ls` on an empty bucket still behaving as head-bucket — which
settles the log flood, not the prerelease.

#5927 is fixed, but it was a whole-class reminder: if a sibling lands in
another scanner module, the EnvFilter directive that fixed it targets one
module path, not a class of bug, and would need widening.

## PROVEN ONCE — Cilium 1.20.0 datapath comes up on Talos-in-Docker

Everything verified for the 1.19.5 → 1.20.0 bump was static: chart digest
cross-checked three ways, all eight `--set` values confirmed present in the
schema *and* landing in the render, KubePrism intact, capability list exactly
our 11. Nothing proved the datapath — until 2026-08-17, on Talos v1.13.8 /
arm64, in rehearsal 1:

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

**Rehearsal 2 re-confirmed all of it on a cold cluster**, and then again on the
second cluster of the day: `Cilium: Ok 1.20.0 (v1.20.0-450c5314)`,
`KubeProxyReplacement: True [eth0 10.5.0.2 (Direct Routing)]`, tunnel/vxlan, no
kube-proxy pods, both nodes Ready at **52 s** of age — and module 05's fault 03
enforced and then stopped enforcing again, so the **policy** path is twice-confirmed
too, not just connectivity.

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

Rehearsal 1, in `bootstrap-gitops.sh`'s 54 seconds: the split is **not**
mis-copied (`startup=/health live=/health ready=/ready`), the deployment went
`Progressing` → `Available` in **~10 seconds** with **0 restarts**, and the PSA
`privileged` namespace label — the curation whose loss makes every PVC hang
Pending — is present. Gitea's 5Gi PVC `Bound` within the same minute. Against
`wait_rollout`'s 300 s × 2 the "probe budget ≈ 65 s" worry is a non-event.

Rehearsal 2 re-confirmed it on a cold cluster in a 1:09 bootstrap: image
`docker.io/rancher/local-path-provisioner:v0.0.37` deployed, `storageclass
local-path` present, wave 0 Synced/Healthy inside module 02's **8-second** solve.

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

**The curation is gone as of 2026-08-17, and rehearsal 2 re-proved it without the
confound that dogged the first test** — `kourier.yaml` carries upstream's
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

**Rehearsal 2 repeated the whole measurement on a fresh gateway on an unloaded,
cold-built 8-CPU cluster** — no suspended auto-sync, no hand-applied ConfigMap, no
saturated worker — and it came out the same shape byte for byte: **1/1 Running,
`restartCount = 0`**, zero `bind` / "Address family not supported" lines in the log,
**8 × `[::]:9000`** in `/proc/net/tcp6`, the IPv4 side untouched (8 × `:8080`,
8 × `:8081`, 8 × `:8090`, `127.0.0.1:9901`), and `GET /stats/prometheus` over IPv4
answering **200 with 171,452 bytes** through `ipv4_compat`. Module 06 passed 8/8 with
the cold-start curl and scale-to-zero at ~40 s.

**If this ever regresses, the symptom is immediate and unmistakable:** the
static listener cannot bind → `3scale-kourier-gateway` crashloops at process
start (bind / "Address family not supported" in `kubectl logs`, readiness on
`:8081` never reached) → **module 06 loses all ingress**. The fix is to put
`address: 0.0.0.0` back and drop `ipv4_compat` — but check
`/proc/net/if_inet6` and `bindv6only` in the pod first, because the real question
would be what took IPv6 out of the netns.

**One honest caveat, and one retired.** (1) Still one machine, one architecture, one
CNI version — settled, not proven; re-run module 06 on the next Knative or Cilium
bump. (2) **The confound is gone.** Rehearsal 1's test ran against an already-loaded
cluster where the CPU cap dominated it: the gateway sat in `ContainerCreating` for
~11 minutes on the Cilium CNI ADD and the *old* pod restarted twice on liveness
`504`/timeout while it waited (both exits code 0 "Completed" — kubelet-initiated, not
Envoy). None of that was ever about IPv6, and on the uncapped cluster none of it
happens: the gateway is 1/1 in seconds with 0 restarts. Those old restarts were
evidence for fixing the CPU caps, and the caps are fixed.

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

**The same shape turned up once more in rehearsal 1, in code rather than prose.**
The Console's Workshop page — advertised in `lab/README.md` as "a live dashboard
of which modules your cluster has reached" — could never mark module 04 Done:
`apps/portal/internal/web/workshop.go` listed `WorkshopDatabases` **cluster-wide**
while the portal's only grant is the namespaced Role module 08 hands it, so the
403 zeroed `WDBCount` and the row could score at most 1/2. It read *In progress*
on a cluster with crossplane Synced/Healthy, two Ready WorkshopDatabases and
`lab/04-self-service/verify.sh` at 10/10. Fixed `c1faf23` by scoping to `demo` —
which is what the field's own comment (`// WorkshopDatabases in ns demo`) and the
row's own hint already claimed. It is Go source, so it needed a portal release before
anyone could see the fix — **released as `cloudbox-portal:v0.2.1` and confirmed in
rehearsal 2**: `GET :30600/workshop` renders module 04 as **Done**, with every other
module inferring correctly around it (05 correctly "Manual check", 09 correctly "Not
started" before the capstone ran). The page is not merely rendering, it is inferring.

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

**Rehearsal 2 is the first run to exercise this from truly nothing.** The mirror
volume was destroyed before the run, so `cloudbox-init.sh` rebuilt all 66 refs
(3 host + 63 cluster) for linux/arm64 in **one 11:35 pass, 7,254,911,019 bytes RX on
`en0`** — 7.25 GB against the README's published "~7.5 GB (arm64)", so the figure is
honest — with zero warnings, zero retries and zero failures. `install.sh --check` then
reported **mirror arch matches (arm64)** across 62 repositories, and every module
downstream pulled from it. (Rehearsal 1 lost one image to a transient blob fetch and
needed an 11:03 + 2:29 two-pass; that retry gap has since been closed in
`cloudbox-init.sh`, and rehearsal 2 never had to exercise it.)

**The other half of offline-first is the reaches nothing gates, and rehearsal 1
found the earlier leak fix was incomplete.** `solutions/module-07/post.sh`
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
| Backstage is amd64-only | Upstream ships it that way; Apple Silicon runs it emulated. Listed in `MIRROR_ARCH_EXEMPT`. **Rosetta turns out not to be required:** on 2026-08-17 it ran under Colima with `vmType: vz` and **`rosetta: false`** — 1/1, 0 restarts, `:30700` → 200, zero error lines. **And the famous 9-minute start was the CPU cap, not the emulation:** same image, same `vz`/`rosetta: false` Colima, uncapped nodes → **57 seconds** to Ready in rehearsal 2, a 9.5× improvement from a change that has nothing to do with Backstage. Keep the "start it early" guidance in module 08 as a **4-core** caveat, where the old number will still roughly apply; on 8 cores it is now over-cautious. |
| module 10 scenario 3 never shows `ImagePullBackOff` — anywhere, even offline | Correct by design, and for a **deeper reason than the `skipFallback: false` fallback** everyone assumed. `cloudbox-init.sh` stores mirror content under the **registry-stripped** repo path (`ghcr.io/knative/helloworld-go` → `knative/helloworld-go`) and `create-cluster.sh` points the *docker.io* mirror at that same registry, so the poisoned `docker.io/…` ref with an identical path and digest is a **mirror HIT**. Measured in rehearsal 1: `containerd/v2.2.6` requested manifest and every blob with `?ns=docker.io` and got `200` from `cloudbox-mirror`; pull time 265 ms; the traffic never left the laptop. **Rehearsal 2 confirmed it on a *cold-built* mirror rather than an inherited one:** the pods go straight to `Running` on `docker.io/knative/helloworld-go@sha256:c2b7412f…`, and `verify.sh` asserts the policy violation (full cycle 2:02, then 8/8 after the revert). So the pull succeeds offline too — the failure is reserved for refs the mirror does not carry, or clusters built without the pre-pull. Do not "fix" the manifest, and do not restore an `ImagePullBackOff` expectation to the check: the scenario and `verify.sh` were rewritten to assert the policy violation reaching the cluster instead (see `lab/10-day2-ops`). |
| module 10 scenario 2's poison is `2Mi`, which "cannot be a plausible rightsizing" | Deliberate and calibrated, and it replaced an `8Mi` that produced **no symptom at all**. On containerd 2.2.6 + runc, `helloworld-go` is Ready and restart-free at 4/6/8/12Mi (8Mi survived 300 sequential and 4800 concurrent requests before *one* replica OOMKilled — unusable as a lab), while ≤3Mi never starts. At `2Mi` the sandbox fails in seconds with the runtime naming the cause: `FailedCreatePodSandBox … container init was OOM-killed (memory limit too low?)`. **Re-confirmed live in rehearsal 2:** the symptom arrives on its own in **~75 s** with no load generator (`FailedCreatePodSandBox` ×6, pod stuck `ContainerCreating`), full inject→revert cycle **2:01**, against rehearsal 1's ~25 minutes of failing to make `8Mi` OOM. The scenario now teaches "a limit is the budget your container is created inside", not a `lastState: OOMKilled` cadence — that signature is not reachable with this image without a load generator. Do not raise the value back toward plausible-looking numbers without re-measuring. |
| `kagent-controller` CrashLoopBackOffs ~3× right after you enable kagent | Ordering, not configuration. It runs its DB migration at startup and starts before `kagent-postgresql` has endpoints (`connect: no route to host`), then self-heals — 1/1 within ~40–90 s, app Synced/Healthy, seen in both rehearsal 1 runs and again in rehearsal 2 (restarted 2×, then Healthy). Module 10 now says so in the text and uses it as a teaching moment. Only read the logs if it is still restarting after ~3 minutes. |
| `application-xr`'s `spec.env` does nothing | Correct — it is **RESERVED, not implemented**. The Composition emits no patch for it; the field stays in the XRD so the v2 append lands without an API break. The VENDOR.md claimed for months that it was "appended"; git history shows the patch never existed. The XRD description now says so. |
| `docker.io/grafana/grafana` vanished from `images.txt` | It was only the `FROM` line in `apps/grafana/Dockerfile`, consumed by CI. No pod ever pulled it. The deployed image is `ghcr.io/randax/cloudbox-grafana`. |
| the preflight says `cilium image (default): v1.19.5`, but we pin 1.20.0 | That line is the **cilium-cli's own built-in default**, printed by `cilium version --client`, not our pin. `create-cluster.sh` installs 1.20.0 by explicit `--version` from `versions.env`. Cosmetic, but `dev-setup.sh` and `install.sh --check` both print it, so a wrong version number appears twice in the output everybody reads before module 01. Do not "fix" it by changing the pin. |
| `cloudbox-init.sh` printed the size warning and then `❌ Aborted.` | It prompts for confirmation and read EOF — you ran it non-interactively (`nohup`, CI, a pipe). Pass `--yes`. An attendee running it by hand never sees this; anyone scripting the prework will, and it looks like a failure rather than a prompt. |

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

**Both real installs took the client-side path in rehearsal 1, verifiably** (on
4.2.3 — that rehearsal predates the 4.2.4 patch by hours, and nothing in 4.2.4's
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

**4.2.4 itself has now run the apply path**, which the paragraph above could not
claim: rehearsal 2 ran on `helm v4.2.4` and both real invocations succeeded on **two**
clusters — Cilium in `create-cluster.sh` (nodes Ready at 52 s, datapath confirmed) and
Gitea in `bootstrap-gitops.sh` (1:09, Gitea and ArgoCD up, 5Gi PVC Bound) — with every
downstream module green. Honest caveat: the `managedFields` `operation=Update` check
was **not** repeated on 4.2.4, so what is proven is "the installs work", not "the
client-side path was taken"; re-run the one-liner above at the next helm bump.

**Retire the flags when:** a full `bootstrap-test` is green with them removed.
Nothing was odd in either rehearsal, so there was nothing to A/B against; the flags
were left in place. On this evidence the experiment looks safe to try, but it is
a separate change, not a side effect of a rehearsal.

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

## RESOLVED — the Console's Case file could not read kagent 0.9.12's stream

**Fixed in `cloudbox-portal:v0.2.1`; proven rendering in rehearsal 2.** The frame
shapes below are kept because they are the only written record of what kagent 0.9.12
actually emits, and the next portal or kagent bump has to hold against them.

Module 10's second half is "open an investigation in the Console and watch the
tool-call log". Against the pinned kagent **0.9.12** that surface used to produce
exactly one thing: *"Investigation failed — the agent responded in a format this
console doesn't recognize. Check that your kagent version matches the workshop pin."*
— a message that sent the attendee after a version problem that did not exist.

**The run was always fine; the translation was not.** Driven end to end in rehearsal 1
(the Console's own endpoint, `POST /agent/ask` for `demo/Component/demo-web`,
scenario 1 injected), the controller answered `200` after **87 s** and the agent
really worked:
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

`apps/portal/internal/kagent/kagent.go`'s `translate()` accepted top-level
`kind: "message"`, `"tool-call"` and `"tool-result"` — kagent emits none of those,
so every frame was dropped, `emitted == 0`, and `agent_ask.go:233` rendered the error
card. The code's own comment (`reconcile against live kagent at rehearsal — see
spec #133 rehearsal gates`) marked this exact gate; rehearsal 1 was that
reconciliation, and it failed.

**Fixed in the portal, exactly there:** `translate()` now reads tool steps out of
`status-update.status.message.parts[].data`, narration out of its `text` parts, and
the answer out of `artifact-update`. Shipped in `ghcr.io/randax/cloudbox-portal:v0.2.1`
and **driven through the Console's own endpoint in rehearsal 2**, against kagent 0.9.12
with host-side `ollama 0.32.14` / `qwen3:4b`:

    HTTP 200, 2,468 bytes, 126 s
    event: tool_call     k8s_get_pod_logs(container=web, namespace=demo,
                                          pod_name=demo-web-…, tail_lines=50)
    event: tool_result   ↳ listen tcp: lookup tcp/8080-canary: unknown port
    event: message       (narration)
    event: verdict       Status / Hypothesis / Kill-test / Fix cards
    event: done

**Zero error frames, `emitted > 0`**, and the verdict names the real cause — the
non-numeric port `8080-canary` — from evidence the agent actually fetched rather than
from restating the symptom. That is the "one investigation renders tool calls and a
verdict in the browser against kagent 0.9.12" this entry's *retires when* clause asked
for. `lab/10-day2-ops/README.md` was corrected in `4e2817b`; the old symptom survives
there as a one-line "if you see this, your portal image predates v0.2.1".

**Unplanned teaching bonus, worth keeping:** the agent's *Fix* card is wrong in
**method** — it proposes `kubectl get deployment demo-web -o yaml > demo-web.yaml &&
sed -i … && git push`, i.e. dumping live state into a file instead of reverting the
offending commit in `gitops/components/demo/demo-web.yaml`. Correct diagnosis, wrong
hands. That is principle 9's "verify the agent" in one screenshot, for free.

**Watch on the next bump:** the translation is coupled to undocumented A2A frame
shapes. If a kagent bump changes them, the symptom is the same error card, and the
diagnosis is to capture `POST /api/a2a/kagent/k8s-agent/` `message/stream` again and
compare against the table above.

## PROVEN ONCE — the kagent inference path, and what is still unproven

Rehearsal 1 could not exercise this at all (no `ollama` on the host, so
`cloudbox-init.sh` warned and skipped the model pull). Re-driven the same day against
the still-running cluster, with `ollama 0.32.14` installed from Homebrew and
`qwen3:4b` pulled — and then re-run end to end **through the Console** in rehearsal 2,
where `cloudbox-init.sh` also found the host model and reported
`✅ Host-side Ollama model qwen3:4b is ready for kagent`:

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

**SUPERSEDED on 2026-08-18 by measurement, in both halves — read the entry below.**
The 11.5 GiB number was right and the diagnosis ("the context window, not the weights")
was right; the *fix* was not "live with it". `num_ctx` came down to **16384** and the
model to **qwen3:1.7b**, and the pin is now `qwen3:1.7b` + `num_ctx: 16384` +
`num_predict: 1200`.

**WATCH — the residue, in the order it would bite:**

1. ~~**The Console surface is broken.**~~ **Retired.** Everything above was originally
   driven through logs and the raw A2A stream; rehearsal 2 drove a full investigation
   through the Console's own `POST /agent/ask` against `cloudbox-portal:v0.2.1` and got
   `tool_call → tool_result → message → verdict → done` with zero error frames, in
   **126 s** (against the raw-stream run's 87 s — the Console path is not free).
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

**Retires when:** ~~one investigation renders in the browser~~ (done, rehearsal 2),
and one beat-2 run against a hosted provider returns a verdict. Only the second half
is outstanding.

## RESOLVED — beat 1 took the laptop apart, and `num_ctx` was 75% of the reason

**Fixed on 2026-08-18** (`qwen3:1.7b` + `num_ctx: 16384` + `num_predict: 1200` in
`gitops/components/kagent/kagent.yaml` and `KAGENT_OLLAMA_MODEL` in `versions.env`).
Rehearsal 3 ended a clean module 10 end state — 21/21 apps, 73 pods,
`/proc/pressure/cpu some avg10=3.10` — and then ran two Case file investigations against
host `qwen3:4b`. Pressure went to **93.48**, host load average to **86**, ~25 pods into
liveness restart loops, module 09's Broker to `EndpointSlicesUnavailable`, five apps out
of Synced+Healthy. `ollama stop` recovered it in 62 s, so it was a resource conflict, not
a wedge.

**The arithmetic, from Ollama's own memory breakdown** (M1 Max, 32 GB, 16 GB Colima VM,
21 apps + 76 pods running):

| model / `num_ctx` | `ollama ps` | weights | KV cache |
|---|---|---|---|
| `qwen3:4b` / **64000** (chart default) | **12 GB** | 2.68 GiB | **9000 MiB** |
| `qwen3:4b` / 32768 | 7.5 GB | 2.68 GiB | 4608 MiB |
| `qwen3:4b` / 16384 | 5.1 GB | 2.68 GiB | 2304 MiB |
| `qwen3:4b` / 8192 | 3.9 GB | 2.68 GiB | 1152 MiB |
| **`qwen3:1.7b` / 16384** (the pin) | **3.4 GB** | ~1.4 GiB | 1792 MiB |
| `llama3.2:3b` / 16384 | 4.0 GB | ~2.0 GiB | 1792 MiB |

**A smaller model alone would barely have helped.** The KV cache is **75% of the 12 GB**;
the 4B of weights is 2.7 GiB of it. `num_ctx` is the lever, and the model size is the
second one — 12 GB → 3.4 GB, i.e. **8.6 GB handed back to macOS**, is both together.

**`8192` is disqualified, not merely tighter.** One `k8s_get_events` result on this
cluster is **~8.2 k tokens on its own** (measured: `task.n_tokens = 8194` on the second
turn), so the agent overflows its own context the first time it reads events. **16384 is
a floor.**

**The second finding is the one nobody was looking for: `kagent-controller` 0.9.12 cuts
the A2A stream at a hardcoded 180 s.** Three runs ended at `duration 180.04 / 180.01 /
181.39` on `POST /api/a2a/kagent/k8s-agent/`, and the Console renders that as
*"The investigation didn't complete … SSE stream error: context deadline exceeded"*.
The portal's own `Timeout: 6 * time.Minute` (`apps/portal/internal/kagent/kagent.go:120`)
is **not** the binding limit and never was — it is twice the real ceiling. There is no
flag, arg or env for the controller's 180 s in chart 0.9.12; re-check it at the next
kagent bump. The failure mode that reaches it is always the same: a small model handed a
large tool result generates without stopping (runs past **9,000 tokens in one turn** were
recorded). `num_predict: "1200"` is what bounds it, and it is load-bearing.

**Why the model changed too, and it is not the reason you would guess.** At
`num_ctx: 16384`, `qwen3:4b` answered **with no tool call at all in four of five runs** —
straight from the opening prompt to an invented verdict — which renders an *empty* Case
file and costs module 10 its centrepiece. Ten investigations against a live scenario-1
fault, all through the Console's own `POST /agent/ask`:

| model / `num_ctx` / `num_predict` | runs | completed with a verdict | real tool calls | wall clock | hit the 180 s cap |
|---|---|---|---|---|---|
| `qwen3:4b` / 64000 / – | 1 | 0 | 1 | 179 s | **yes** |
| `qwen3:4b` / 16384 / – | 5 | 4 | **0 in 4 of 5** | 95–178 s | 1 |
| `qwen3:4b` / 16384 / 1200 | 3 | 0 | 0–1 | 42–86 s | 0 (truncation broke it instead) |
| `qwen3:1.7b` / 16384 / – | 6 | 3 | 2–6 | 43–184 s | 3 |
| **`qwen3:1.7b` / 16384 / 1200** | **10** | **9** | **4–26** | **31–106 s** | **0** |
| `llama3.2:3b` / 16384 / 1200 | 6 | 6 | 4–18 | 21–33 s | 0 |

`llama3.2:3b` measured slightly better and was **rejected on licence**: Llama 3.2 ships
under Meta's Community License, not an OSI-open one, and "Cloud on your terms" should not
pre-pull a non-open model when an Apache-2.0 one in the same family does the job.

**Beat 1 still flails, and better than before** — 9 of 10 runs. The *shape* changed, so
`lab/10-day2-ops/README.md`'s calibration paragraph was rewritten: it is no longer "one
tool call, then a printed `<function-call>` block". It is 4–26 real tool calls, breadth instead of
depth (one run walked `k8s_get_resources(all_namespaces=true)` across **nineteen**
resource types and never asked the crashing pod for its logs), calls against objects that
do not exist (a pod name passed as a *Deployment*, a `demo` pod looked up in namespace
`default`), a verdict that **narrates the JSON it just downloaded** instead of reading
it — and, once, a verdict diagnosing its own failed tool call as "likely localized to
your environment". **~1 run in 10 it
does land on `PORT=8080-canary`** — and that run also asserted "the Service is configured
to use 8080-canary", which is false. A correct headline with an invented supporting fact
is the best principle-9 artifact this module has ever produced; the README now points at
it directly.

**Criterion 4, live:** three and four back-to-back investigations at the new pin left the
cluster at 21 apps unchanged, both nodes `Ready`, and a cluster-wide **restart delta of
0–2** (against rehearsal 3's ~25 pods in liveness loops). VM memory pressure peaked at
`some avg10=37`, never below **7.0 GB** available inside the VM. VM *CPU* pressure is
**not** a usable discriminator on the machine this was measured on — two identical
`qwen3:1.7b` batches twenty minutes apart peaked at 39.2 and 92.9 because the host was
also running Zoom, Slack and a photo-library index; the idle control over the same
cluster read `some avg10=3.92`. The footprint numbers in the first table are the
deterministic evidence; treat the pressure numbers as this-machine-that-afternoon.

**Retires when:** one full rehearsal runs module 10 beat 1 end to end at the new pin on a
quiet machine, and one run happens on a 16 GB laptop — the "beat 1 does not fit on 16 GB"
line is *still* a claim, now with 3.4 GB in it instead of 11.5 GB, and still unmeasured
there.

## PROVEN ONCE — smaller things the rehearsals settled

Unlabelled rows are rehearsal 1; rehearsal 2's re-confirmations are marked inline.

| What | What was measured |
|---|---|
| **NATS 2.14 liveness** | Ready **2/2 in 25 s**, 0 restarts, `/healthz` and `/healthz?js-enabled-only=true` both `{"status":"ok"}`, JetStream up, PVC Bound (rehearsal 2: 2/2, 0 restarts, ~25 s again). **And the premise was wrong:** `local-path` is a hostPath bind that does not enforce the 1Gi request — inside the pod `/data` reports the node's whole 97.9 G — so "a full PVC CrashLoops the pod" needs the *node* disk to fill, not the PVC. Much less reachable than feared, and also: nothing bounds JetStream's growth. |
| **BuildKit v0.32.2, module 07** | `moby/buildkit:v0.32.2-rootless` came up **2/2 in 15 s** and the workflow reached `Succeeded` inside the 91 s solve, on kernel 6.8.0-117 arm64 / containerd 2.2.6, PSA-privileged `builds` namespace. No runc or rootlesskit trouble at all. Rehearsal 2 re-ran the whole chain on a cold cluster, twice (module 07 and again through `catch-up.sh`), and the build Succeeded first try both times. |
| **zot v2.1.20 under chart 0.1.122** | Tag override in effect (`:v2.1.20` over the chart's declared v2.1.18), 1/1 in 16 s. **Anonymous push works** — `crane copy --insecure` with no credentials — and `:30500` answered 200 on `/v2/`, `/` (UI extension) and `/v2/_zot/ext/search` (GraphQL). One non-finding: `/v2/_zot/ext/discover` **404s** at 2.1.20; that endpoint does not exist there, the extensions are plainly enabled. Rehearsal 2 re-confirmed the anonymous `crane copy` seed and the catalog read on a cold cluster. |
| **Grafana Explore deep-link** | **This was not an unproven nicety — it was broken.** Anonymous Viewer does not carry the `datasources:explore` RBAC action (26 actions, without it), so Grafana answered every `/explore…` request with `302 → /?redirectTo=…` and, since an anonymous session never logs in, **discarded the `panes` payload entirely**: every Console deep-link landed on the Grafana home page. `/` and `/dashboards` returning 200 is what made it easy to miss. Fixed in `d608d88` with `GF_USERS_VIEWERS_CAN_EDIT=true` (marked load-bearing in the component's VENDOR.md) and verified served: bare `/explore` **200**, deep-link **200**, `datasources:explore` granted, `dashboards:write` still denied (27 actions), the `panes` JSON parses, its uids resolve, and both carried expressions return data through the proxy (`sum(k8s_pod_cpu_usage{k8s_namespace_name="observability"})` → 0.0623, `sum(cnpg_backends_total{cnpg_cluster="my-db-pg"})` → 1). **Still one human click from "renders prefilled"** — neither rehearsal had a browser, and rehearsal 2 did not re-check it at all. (`GF_AUTH_ANONYMOUS_ORG_ROLE=Editor` is the one-line alternative; it grants more than Explore.) |
| **OTel 0.158.0 deprecation WARNs** | **The count was wrong: 4 on the agent, not 3.** Gateway is 5 as predicted (`otlphttp` ×3, `spanmetrics`, `servicegraph`); the agent emits `otlphttp` ×2, `kubeletstats` **and `filelog`**, identically on both DaemonSet pods — so **13 cluster-wide**, once at startup each. Legacy IDs stay on purpose: renaming makes the config unloadable on 0.149.0, breaking rollback. Pre-empt the corrected count in the module 09 text. |
| **Module 09 trace waterfall** | **One connected trace: 37 spans, exactly 1 root, 0 spans with a missing parent** — `cloudbox-portal POST /gallery/upload` → activator → uploader → `s3 put original` → `broker.ingress` → in-memory channel → `broker.filter` → activator → resizer → `s3 download` / `decode and resize` / `s3 upload thumbnail and meta`. It does not fragment: the re-applied `config-observability` keys (nine in serving, six in eventing — the curation the VENDOR.md audit found missing) are what buys this. VictoriaTraces knew all 10 services. Whole observability stack Synced/Healthy in ~90 s. **Rehearsal 2, cold cluster: 122 spans, still exactly 1 root (`POST /gallery/upload`), still 0 orphans**, 9 services in the trace and 10 known to VictoriaTraces; five observability apps Synced/Healthy in 2:06. More spans, same shape — the property is the root/orphan count, not the span count. |
| **Argo Workflows v4.1.1** (rehearsal 2) | The bump was made on static evidence; a real rootless BuildKit build now backs it. `workflow-controller:v4.1.1`, workflow **Succeeded**, `hello-site` in the zot catalog and serving, and the pod layout is `init=init, containers=wait,main` — **the legacy init+wait layout is intact**, which is what rootless BuildKit depends on. v4.1.0's opt-in `initlessPod` did not arrive with the bump: `grep -rn initlessPod gitops/ --include='*.yaml'` → **0 hits**. |
| **`catch-up.sh` as a rebuild path** (rehearsal 2) | After the `92aac7a` fix, one `catch-up.sh 10` on a cluster that had not existed twenty minutes earlier reproduced the entire workshop end state in **4:13**: 19/19 Applications Synced+Healthy (module 10's canonical set), 63 pods all Running or Completed, and an eleven-module `verify.sh` sweep at **11/11 exit 0**. The two `○` star tasks are correctly *not* restored — they are human moments, and both `verify.sh` scripts say so and pass anyway. |

**Louder than any of those 13 one-shot WARNs, and unresolved:** the OTel gateway
logs a **failed Prometheus scrape every 30 s, forever**.
`net-kourier-controller` ships the `prometheus.io/scrape` annotations and
declares port 9090, but Knative 1.23 moved its metrics to the OTel pipeline and
opens nothing there — so `connection refused`, one target, one WARN per interval.
Harmless, permanent, and the only *recurring* error-shaped line in the stack.
Silencing it needs either a curation dropping the upstream annotation or a drop
rule in the receiver; both are curation decisions nobody has taken. **Not re-checked
in rehearsal 2** — nothing suggests it changed, and the same goes for the OTel WARN
counts above.

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

**Decided and shipped 2026-08-17, and exercised end to end in rehearsal 2** — which
was the first run to take the new code path on a cold cluster, twice.
`public.ecr.aws/aws-cli/aws-cli:2.36.24` was
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

**The one real trap the swap exposed, and it was pre-existing. Reproduced live in
rehearsal 2, against the real store.**
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

**Rehearsal 2 confirmed all three states on the live cluster**, running both branches
of `lab/03-data/verify.sh`'s `s3ls` by hand: a missing bucket gives `rc = 1` with
`ERROR "ls s3://…": NoSuchBucket … status code: 404` **on kubectl's stdout**, which the
`^ERROR ` filter empties; an existing empty bucket gives `rc = 0` and empty stdout; a
populated one lists keys. The pre-solve run correctly said *"bucket app-assets not
found"* — the true answer, not the false pass a naive port would have produced. The
`mb`-on-existing-bucket and `ls`-on-empty-bucket behaviours above were re-confirmed at
the same time.

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
  exercised before. **Rehearsal 2 priced it:** module 03 solve 1:03 → 2:33, module 04
  0:51 → 2:00, module 09 0:51 → 2:48 (**~+1:45**, the poll loop spawning a pod per
  poll). Irrelevant against 35-minute module budgets; it makes `bootstrap-test.yaml`'s
  module 09 job roughly **2.5× longer**, which is the thing to watch — in CI, not here.
- **The PodSecurity warning wall is louder now, and permanent.** Every helper pod
  (`solve-s3`, `verify-s3`, module 05's fault workloads) emits the four-line
  `restricted:latest` warning — `allowPrivilegeEscalation`, `capabilities.drop`,
  `runAsNonRoot`, `seccompProfile` — on each `kubectl run`/`apply`, and now that
  nobody has `s5cmd` locally the pod branch always runs. Cosmetic, guaranteed to be
  asked about in a room of 80, and the noisiest thing in a solve log.
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
