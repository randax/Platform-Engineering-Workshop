# Rehearsals — what the day actually costs, and what testing it taught us

Every end-to-end run of this workshop gets a record. The per-rehearsal records
live in `docs/rehearsals/`, one file each, indexed below; this file keeps the
timing envelope the early runs produced and the lessons that generalise across
all of them. `docs/HAZARDS.md` is what to be afraid of; this is how we found it.

Raw records (per-stage logs, evidence files) are not in the repo — they live in
the run scratchpads referenced from each hazard entry.

## Index

| # | date | substrate | outcome |
|---|------|-----------|---------|
| [1](rehearsals/01-warm-mirror-first-pass.md) | 2026-08-17 | docker (Colima) | warm mirror, 11/11 green, ~16 min script time; 3 blockers, 2 invisible to CI |
| [2](rehearsals/02-cold-start-rebuild.md) | 2026-08-17 | docker (Colima) | cold start, 11/11 on two clusters incl. `--rebuild`; the `catch-up.sh` deadlock |
| [3](rehearsals/03-cold-mirror-uncapped.md) | 2026-08-17/18 | docker (Colima) | cold mirror, uncapped nodes, 10/11 (host disk); the 36-node-cluster context near-miss |
| [4](rehearsals/04-brand-new-colima-vm.md) | 2026-08-18 | docker (fresh Colima VM) | from zero, 11/11 **twice**; two recovery-path blockers, one self-inflicted |
| [5](rehearsals/05-substrate-split-checklist.md) | (planned) | tbx | the substrate-split checklist — steps, not results; timings blank on purpose |
| [6](rehearsals/06-first-tbx-end-to-end.md) | 2026-08-28 | tbx | first VM run, labs 01–08 in ~1 h 33 min; the crane-hop image-pull stall |
| [7](rehearsals/07-tbx-pinned-release.md) | 2026-08-29 | tbx v0.1.4 | full path to module 10, 0 manual recoveries; the self-healed VM reboot |
| [8](rehearsals/08-agy-participant-run.md) | 2026-08-29 | tbx | an outside agent (agy) completed 00–09 unaided; tbx-mirror and prework finds |
| [9](rehearsals/09-tbx-kernel-panic-v013.md) | 2026-08-30 | tbx v0.1.3 | **aborted: tbxd panicked the macOS kernel** — host hard reset, 0 modules |
| [10](rehearsals/10-tbx-kernel-panic-v014.md) | 2026-08-30 | tbx v0.1.4 | **aborted: second panic, 18 min later** — the upgrade remedy spent; tbx off that host |
| [11](rehearsals/11-docker-first-full-run.md) | 2026-08-30 | docker | 00–09 for real on PR #222; the module 08 storage trap, adventure 3's inert default-deny, the `curl -4` fix |
| [12](rehearsals/12-docker-merged-main.md) | 2026-08-30 | docker | merged main at the resource floor, all eleven `verify.sh` exit 0; lab 08's verify graded on the lying `status.phase` |
| [13](rehearsals/13-adventures-and-recovery.md) | 2026-08-30 | docker | adventures + recovery tooling, no happy path; ArgoCD's silent give-up after 5 retries, `catch-up.sh` proven idempotent |

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

Rehearsals 11 and 12 re-earned this one from both sides in a single night: three
lab verifiers failed healthy modules over a curl AAAA stall, and lab 08's own
`verify.sh` graded a wedged database healthy off the same `status.phase` field
its lesson calls a liar.

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

### What rehearsals 9 and 10 added: a substrate can take the host with it

Every failure before 2026-08-30 cost a cluster at worst. The tbxd kernel panics
cost the *machine* — twice, on two releases, with no warning — and the remedy
was not a fix but a retreat that worked: uninstall the substrate, let detection
choose docker, keep testing. A rehearsal that ends in a kernel panic is still a
rehearsal, and recording it as one is what turned "the laptop rebooted" into a
hazard entry with an on-the-day playbook.
