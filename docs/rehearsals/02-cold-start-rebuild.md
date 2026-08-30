# Rehearsal 2 — cold start and the recovery path (2026-08-17, evening)

The cold-start proof: cluster *and* mirror destroyed first, the full 7.25 GB
pre-pull re-run from nothing, and the first run of `catch-up.sh 10 --rebuild`.
Same Apple Silicon + Colima laptop as rehearsal 1. This run still had the node
CPU caps in place for part of it — which is why it is the slow column in the
comparison table, and why its before/after is the decisive evidence for the
CPU-cap fix.

## Setup

- Substrate: Talos-in-Docker, Colima (8 CPU / ~16 GiB).
- Mirror: **cold** — destroyed and re-warmed as part of the run.
- Two clusters: the forward path, then a second cluster built by
  `catch-up.sh 10 --rebuild`.

## Results

| | rehearsal 2 |
|---|---|
| modules | 00→10, **11/11 `verify.sh` exit 0 on two clusters** |
| total script time | **~32 min** (the slow run — capped node CPUs) |
| `cloudbox-init.sh`, cold | 11:03 (7.25 GB) |
| `create-cluster.sh`, cold mirror, unattended | 2:09 first attempt, nodes Ready at 52 s of age |
| `catch-up.sh 10` after the deadlock fix | **4:13** on a twenty-minute-old cluster, then 11/11 verify |
| bugs found | 4 — one a blocker, again where CI cannot look; all fixed the same evening (`1f12353`, `ca4859e`, `92aac7a`, `4e2817b`) |

With the caps off, the module 10 end state that wedged rehearsal 1 came up
clean: CPU pressure 1.08 against 98.72, Backstage **9:03 → 0:57**, 21/21 apps
and 73 pods. ~90× less CPU pressure, and no wedge.

## What broke

- **`catch-up.sh` deadlocked against itself on modules 07–10** (fixed
  `92aac7a`). Its gate waited for `demo` to be Healthy before running the
  `post.sh` whose in-cluster build produces the very image `demo` needs. On a
  fresh cluster it died at ten minutes, every time, with and without
  `--rebuild`. No CI job runs `catch-up.sh` at all — and neither had
  rehearsal 1.
- **`wait_for_cr` on a CRD that does not exist yet does not wait** (fixed
  `ca4859e`) — `kubectl wait` on a named absent object returns NotFound
  immediately, which under `set -euo pipefail` killed `lab/06`'s `solve.sh`
  outright. CI runs every `solve.sh` and had never hit it; the trigger is a
  sync-wave timing race, not bad luck.
- The most instructive failure of the early rehearsals also landed here (fixed
  `4e2817b`): a confident wrong answer produced by the tooling itself — see
  `docs/HAZARDS.md`.

## What it proved

Both rehearsal-1 fixes held on the run where they used to fail: the kubeconfig
stayed on `127.0.0.1`, the context cleanup was real, and the second
`create-cluster.sh` of the day got all the way past Cilium. The extra ~16
minutes over rehearsal 1 is mostly the CPU caps plus added coverage, not
regression. And the pattern that became this project's strongest lesson
started here: two rehearsals, two recovery-path blockers.

Sources: `docs/HAZARDS.md` (rehearsal summaries, the CPU-cap entry's
rehearsal-1/2 comparison table, the recovery-path entries), the timing tables
in `docs/REHEARSALS.md`.
