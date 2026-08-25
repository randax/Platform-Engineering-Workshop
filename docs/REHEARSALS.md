# Rehearsals — what the day actually costs, and what testing it taught us

Three full end-to-end rehearsals ran on 2026-08-17/18, all on Apple Silicon +
Colima. This is the timing envelope they produced and the lessons that outlived
them. `docs/HAZARDS.md` is what to be afraid of; this is how we found it.

Raw records (per-stage logs, evidence files) are not in the repo — they live in
the run scratchpads referenced from each hazard entry.

## The 240-minute budget is not the constraint

**Script time, end to end, all eleven modules: 16–32 minutes.** The rest of the
240 is people reading, typing, asking and getting stuck, which is the workshop.
Nothing measured is close to the budget.

| | rehearsal 1 | rehearsal 2 | rehearsal 3 | rehearsal 4 |
|---|---|---|---|---|
| mirror | warm | cold | cold | **cold, brand-new VM** |
| total script time | ~16 min | ~32 min | ~24 min | ~28 min |
| modules green | 11/11 | 11/11 | 10/11 *(00 red on host disk)* | **11/11, twice** |

Rehearsal 2 is the slow one because it ran with capped node CPUs; rehearsal 3 is
the same workshop with the caps removed. That difference is the single biggest
lever in the table and it is worth understanding before optimising anything else.

Rehearsal 4 ran on a Colima instance created minutes earlier — 0 images, 0
containers, 0 volumes — and passed the eleven modules **twice**: once forward,
once on the cluster `catch-up.sh 10 --rebuild` built. That was the first
successful `--rebuild` in four attempts.

## Prework, at home

| step | cold | notes |
|---|---|---|
| `dev-setup.sh` | 0:01–0:02 | tools already installed; a real first run pulls them |
| `cloudbox-init.sh` | **11:03 – 13:39** | 7.25–7.87 GB, 66 refs, 0 retries |
| *(plus the host Ollama model)* | — | ~1.4 GB, pulled by the same script, never separately measured |
| `cloudbox-init.sh` (re-run) | 2:17 | idempotent; nothing re-downloaded |
| `install.sh --check` | 0:08–0:09 | identical **with the network down** |

The pre-pull is the long pole of the entire workshop and it happens days early on
a home connection. That is the design working.

## At the venue

| stage | best | worst | budget |
|---|---|---|---|
| `create-cluster.sh` (cold mirror) | 2:09 | 2:24 | module 01, 35 min |
| `bootstrap-gitops.sh` | 0:47 | 1:09 | module 02, 35 min |
| `seed-gitea.sh` | 0:06 | 0:06 | module 02 |
| module 03 solve | 0:46 | 2:33 | 35 min |
| module 04 solve | 0:46 | 2:00 | 35 min |
| module 05 (4 faults, settle, restore) | 1:11 | ~4:30 | 25 min |
| module 06 solve + verify | 1:03 | 1:14 | stretch |
| module 07 solve (in-cluster build) | 1:04 | 2:21 | stretch |
| module 08 solve | 0:44 | 1:32 | stretch |
| module 09 solve | 0:29 | 2:48 | stretch |
| observability stack (module 09 step 5) | 0:45 | 2:06 | stretch |
| module 10, three scenarios | 0:20–0:42 each | up to ~25 min *(before the scenario fixes)* | stretch |
| `catch-up.sh <n>` | 0:10 | 4:13 *(fresh cluster)* | recovery |

Two numbers worth carrying into the room:

- **Backstage: 9:03 → 0:57** once the node CPU caps came off. If a demo is
  crawling, suspect resource starvation before anything else.
- **The s5cmd swap costs ~1:00–1:45 per storage module**, because it takes the
  in-cluster pod branch rather than a preinstalled binary. That is the attendee
  path and better coverage; it is not free.

## Rehearsal 5 — the substrate split (planned)

Rehearsals 1–4 all ran Talos-in-Docker. The substrate split adds a second machine
substrate — real Talos VMs via [talos-box](https://github.com/randax/talos-box) —
and **not one line of that path has been run end to end.** Everything below is
therefore a checklist, not a result. Timings are blank on purpose: the owner
fills them in on the day, the way the four numbers in the table above were filled
in.

`sudo tbx system install` is a **one-time privileged prerequisite** — it installs
the helper that does the VM and network wiring. It is not part of any script and
nobody should discover it at the venue.

Each step names the `docs/HAZARDS.md` entry it retires, so a green run can be
turned into edits there rather than into a feeling.

| # | Step | Time | Result |
|---|------|------|--------|
| 0 | portal release + re-mirror (below) | | |
| 1 | `tbx system install` / `tbx doctor` | | |
| 2 | prework: `cloudbox-init.sh`, `install.sh --check` | | |
| 3 | `create-cluster.sh` | | |
| 4 | registry mirror reaches the VMs | | |
| 5 | bootstrap + seed, ingress on the hostname | | |
| 6 | labs 01–06 | | |
| 7 | module 07 (registry + in-cluster build) | | |
| 8 | modules 08/09 (Console, picture pipeline) | | |
| 9 | module 10 (kagent + Ollama) | | |
| 10 | destroy → create → `catch-up --rebuild 07` | | |
| 11 | full-tunnel VPN | | |
| 12 | offline | | |
| 13 | docker path on the same Mac | | |
| 14 | `bootstrap-test.yaml` | | |

**0. Publish the portal image first.** Merge the branch, let `release-please` open
its release PR (it rewrites every pinned ref — pins are never hand-edited), merge
that, wait for `build-images` to finish, verify every ref in `scripts/images.txt`
resolves with the `crane manifest` loop, then re-run `./scripts/cloudbox-init.sh`
to re-mirror. Until this is done the Console's function URLs are wrong on both
substrates and step 8 cannot pass.
*Retires:* TRAP — the pinned portal image predates `KNATIVE_DOMAIN`. *Guards
against:* TRAP — the release/pin publish window.

**1. Install the helper.** `sudo tbx system install && tbx doctor` → **all PASS**.

**2. Prework.** `./scripts/cloudbox-init.sh` → ends with `talos-disk=yes ·
tbx-doctor=pass`. Confirm the disk image is really there, not just its directory:

    find ~/.talosbox/cache -path '*v1.13.8/*disk.raw'

must be non-empty. Then `./scripts/install.sh --check` → exit 0. Note whether the
Ollama bind warning fired.
*Retires:* the offline half of LIVE — Ollama binds to loopback (the warning path),
and confirms the disk-cache assertion added after an interrupted `tbx cache pull`
left a directory behind.

**3. Create the cluster.** `time ./scripts/create-cluster.sh`. Expect: the subnet
line; both nodes in maintenance within **≤300 s**; `Ingress VIP: 172.30.<n>.200`;
and **no** ".200 is not conventional" warning. Record wall-clock — this is the
number the 240-minute budget cares about, and there is no prior measurement for it.
*Retires:* TRAP — `.200` resolves before anything owns it.

**4. The mirror actually reaches the VMs.** `talosctl -n <cp> get registries`
shows the mirror endpoint; the worker's kubelet logs show pulls from
`172.30.<n>.1:5001`; `docker logs cloudbox-mirror | tail` shows them arriving.
This is the step that proves a tbx laptop still needs Docker.

**5. Bootstrap and seed.** `./scripts/bootstrap-gitops.sh && ./scripts/seed-gitea.sh`,
then `dig +short gitea.cloudbox.k8s.test` → the `.200` VIP, and
`curl -I http://gitea.cloudbox.k8s.test` → 200. Watch the git push for Envoy 413s
or timeouts. Gitea's UI clone box shows the in-cluster URL — use the hostname.

**6. Labs 01–06.** `solve.sh` then `verify.sh` for each. Lab 06 must pass **via its
own URL**, not the fallback — and that URL is now
`http://hello-demo.kn.cloudbox.k8s.test/`, one label, from the `domain-template`
curation. Then do the thing the fixed rules exist for: create a ksvc in a namespace
nobody listed (`kubectl create ns scratch` + any ksvc) and confirm it answers on tbx
with no extra Ingress rule. On docker it will not resolve — that is expected and
documented; `curl -H "Host: …" http://localhost/` must still answer.
*Retires:* RESOLVED — a Knative Service in a namespace nobody listed had no route.

**7. Module 07.** `./scripts/catch-up.sh 07 && (cd lab/07-ci && ./verify.sh)`. The
`crane copy` goes to `zot.cloudbox.k8s.test` through the ingress; the in-cluster
build pushes and pulls `localhost:30500` from a real node. Both halves matter —
they are the two sides of the hostname/NodePort split, and the node-side half is
specifically what tbx's catch-all `"*"` mirror would have broken (see the RESOLVED
entry in `docs/HAZARDS.md`). **CI does not prove this**: `bootstrap-test.yaml` builds
the first-party images locally as `v0.1.0` while the manifests pin `v0.2.2`, so the
cluster silently falls back to GHCR and the offline first-party image path is never
exercised on any runner. This step is the only place it is.
*Retires:* the tbx half of the catch-all mirror — the one path a green CI run cannot
speak to.
*Retires:* the tbx half of the catch-up clone-URL fix — `catch-up.sh` used to
clone the platform repo from a NodePort that only exists on docker.

**8. Modules 08 and 09.** `http://portal.cloudbox.k8s.test` loads; upload a
picture; the presigned URL is `http://s3.cloudbox.k8s.test/...` **and loads** (a
`SignatureDoesNotMatch` means the Host rewrite is wrong, not the credentials);
Console app URLs read `<name>-<namespace>.kn.cloudbox.k8s.test` — which is what proves
step 0 landed.
*Retires:* TRAP — the pinned portal image predates `KNATIVE_DOMAIN`.

**9. Module 10.** `OLLAMA_HOST=0.0.0.0 ollama serve`; enable kagent; then

    kubectl -n kagent logs job/kagent-ollama-host -c render-patch     # shows 172.30.<n>.1:11434
    argocd app sync kagent
    kubectl -n kagent get modelconfig default-model-config -o jsonpath='{.spec.ollama.host}'

The last value must be **unchanged** after the sync. Record `tbx status` and the
VM's RSS at this end state — that is what the `TBX_*` memory pins should be
corrected against.
*Retires:* LIVE — Ollama binds to loopback · WATCH — three settings have to agree
for the Ollama host to survive selfHeal · WATCH — `bootstrap-gitops.sh` creates
namespace `kagent` before ArgoCD owns it · and gives LIVE — tbx VM memory is a
moving ceiling its first real number.

**10. The recovery path.** `./scripts/destroy-cluster.sh --purge-mirror &&
./scripts/create-cluster.sh`, then `./scripts/catch-up.sh --rebuild 07`. Rehearsals
2 and 4 both found blockers here and nowhere else.

**11. VPN.** With a full-tunnel VPN connected: `tbx doctor` (expect a `routes`
FAIL), `curl http://gitea.cloudbox.k8s.test`. Document exactly what the attendee
sees.
*Retires:* TRAP — a full-tunnel VPN blackholes 172.30.0.0/16.

**12. Offline.** Wi-Fi off: destroy, create and bootstrap must all succeed from the
mirror and the cached disk image. This is the hard requirement, on a substrate
that has never been asked.

**13. The docker path, same Mac.** `CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh`
→ **one** sudo prompt; `grep -c cloudbox /etc/hosts`; `curl http://argocd.cloudbox.k8s.test`;
`destroy-cluster.sh --purge-mirror` leaves `/etc/hosts` **byte-identical** to what
it was before. Repeat under Colima if it is available on the machine.
*Retires:* TRAP — /etc/hosts needs sudo · LIVE — host port 80 is the only
privileged port the workshop binds.

**14. CI.** `gh workflow run bootstrap-test.yaml` — both jobs green.

**15. The gate.** Keep `CLOUDBOX_SUBSTRATE_DEFAULT="tbx"` **only if steps 3–12
pass**. Otherwise flip it to `docker` in `scripts/versions.env:69` by **Aug 31** and
ship tbx as the opt-in path. The decision is a date, not a judgement call, because
the alternative is discovering the answer in the room.

## What testing this taught us

These are the lessons that generalise. Each one was paid for.

### Rehearse on the platform attendees use

Both blockers that made module 01 **impossible on macOS** were invisible to
`bootstrap-test.yaml` by construction — an `ubuntu-latest` runner can route into
the Talos docker network, and a Mac cannot. A green CI run means "the workshop
works on Linux, on one cluster, with no timing races".

Four rehearsals in, the split is stark: **the platform itself produced the same
numbers every time**, while rehearsals 1, 2 and 4 each found a blocker in the
*recovery or setup* path — the code an attendee reaches for when they are already
stuck, and the code CI exercises least.

### Rehearse the *second* cluster, and the recovery path

`talosctl config remove` silently skips the selected context, so `destroy &&
create` failed on the **second** cluster of the day. CI creates one cluster per
runner and can never see it. Separately, `catch-up.sh` deadlocked on modules
07–10. **Two rehearsals, two recovery-path blockers** — the code path reserved
for people already in trouble is the least exercised one in the project.

### A short measurement window reads *wrong*, not *clean*

RustFS log volume on the same log, same cluster: **300 s read 5.23 MiB/h where
900 s read 1.85** — a 2.8× spread from window choice alone. Reproduced in **all
four** rehearsals, and crucially *in both directions*: a short window read high
in one run and low in another, depending where the scan cadence fell. The rule is
not "short windows read low", it is **short windows read wrong**. And it only
floods once the scanner has objects, so an empty-store test sees nothing at all.
Seed the state, then measure for half an hour.

Related: take rates from `kubectl logs --since=<window>`, never from two `wc -c`
snapshots. One rehearsal's naive byte-delta came out **negative**, because kubelet
rotation ate the burst mid-window.

### Prove the negative

A guard that has never failed is not a guard. Every check added here was made to
fail on purpose first — a deleted PSA label, a dropped config key, nine planted
violations, a synthesised foreign kubeconfig. Two of those exercises found that
the *naive* version of the test would have passed anyway.

### Documented is not measured

- **11 of 19 `VENDOR.md` curation lists were wrong**, each accurate the day it
  was written and rotted at the next bump.
- Module 10's scenarios promised symptoms — `OOMKilled`, `ImagePullBackOff` —
  that **could not occur**, and had shipped that way.
- `seed-gitea.sh` said "idempotent". True of itself, destructive against
  `catch-up.sh`.
- The pinned model was documented as a reliable tool-caller and **made no tool
  call in 4 of 5 runs**.

Prose about a system does not stay true unless something compares it to the
system. That is why the drift guards exist.

### Fix resource conflicts at the source

Node containers were capped at 4 CPUs total, and the module 10 end state wedged
at `/proc/pressure/cpu avg10=98.72` on **23% absolute utilisation** — throttling,
not saturation. Raising the caps *mid-load* did not rescue it: pressure fell to
~92 and had not recovered ten minutes later. The caps have to be right before the
load arrives.

### The tools that report must be trustworthy first

Several bugs were checkers manufacturing their own findings: guards reporting an
HTTP 429 as upstream drift, a preflight probe pulling an image it had told the
attendee not to need, a version row reading `ok` because it resolved the wrong
endpoint. A check that cries wolf gets ignored, and then it protects nothing.

### Verify the mechanism, not just the outcome

Module 05's re-injected faults were fixed on the strength of a wrong explanation
("immutable fields"); the real causes were a `maxUnavailable: 25%` that rounds to
zero on one replica, and an already-Bound PVC. Same fix, different reason — and
the wrong reason was about to ship in a comment attendees read, in the module
about not trusting confident explanations.

### Two lessons rehearsal 4 added

**A fix can be a regression.** The `KUBECONFIG` pin landed fifteen minutes before
rehearsal 4 started, and made every fresh clone of the platform repo an *untrusted*
mise config — so every mise-installed tool run from inside a clone exited 0 with
empty output. `catch-up.sh` `cd`'d into that clone. The change was individually
correct, reviewed, and shipped with tests; it broke a path nothing tested.

**Summarising is where the errors enter.** Every register update in this project
was written by re-reading the raw evidence rather than the previous summary, and
every one of them caught real mistakes in the hand-off: a count of contexts, which
rehearsal failed which module, a download figure quoted as a disk figure, a "same
byte four times" that was three. The measurements were sound each time. The prose
about them was not.
