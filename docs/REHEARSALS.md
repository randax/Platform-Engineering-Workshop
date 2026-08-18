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

| | rehearsal 1 | rehearsal 2 | rehearsal 3 |
|---|---|---|---|
| mirror | warm | cold | cold |
| total script time | ~16 min | ~32 min | ~24 min |
| modules green | 11/11 | 11/11 | 10/11 *(00 red on host disk)* |

Rehearsal 2 is the slow one because it ran with capped node CPUs; rehearsal 3 is
the same workshop with the caps removed. That difference is the single biggest
lever in the table and it is worth understanding before optimising anything else.

## Prework, at home

| step | cold | notes |
|---|---|---|
| `dev-setup.sh` | 0:01–0:02 | tools already installed; a real first run pulls them |
| `cloudbox-init.sh` | **11:03 – 12:19** | 7.25–7.41 GB, 66 refs, 0 retries |
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
works on Linux".

### Rehearse the *second* cluster, and the recovery path

`talosctl config remove` silently skips the selected context, so `destroy &&
create` failed on the **second** cluster of the day. CI creates one cluster per
runner and can never see it. Separately, `catch-up.sh` deadlocked on modules
07–10. **Two rehearsals, two recovery-path blockers** — the code path reserved
for people already in trouble is the least exercised one in the project.

### A short measurement window reads *wrong*, not *clean*

RustFS log volume on the same log, same cluster: **300 s read 5.23 MiB/h, 900 s
read 1.85** — a 2.8× spread from window choice alone. And it only floods once the
scanner has objects to scan, so an empty-store test sees nothing at all. Seed the
state, then measure for half an hour.

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
