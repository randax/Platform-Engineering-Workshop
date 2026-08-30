# Rehearsal 1 — first full pass, warm mirror (2026-08-17, morning)

The first end-to-end run of the whole workshop. Apple Silicon + Colima
(8 CPU / ~16 GiB), Talos-in-Docker, one cluster, mirror already warm.

## Setup

- Substrate: Talos-in-Docker (`talosctl cluster create docker`), Colima.
- Mirror: warm — the pre-pull had already run.
- One cluster, forward path only; `catch-up.sh` was not exercised (a gap
  rehearsal 2 paid for).

## Results

| | rehearsal 1 |
|---|---|
| modules | 00→10, **11/11 `verify.sh` exit 0** |
| ArgoCD Applications | 21/21 Synced+Healthy |
| total script time | **~16 min** against the 240-minute budget |
| blockers found | 3, two of them invisible to any CI job we have |

The run ended on a cluster whose node CPU caps had been raised **by hand**
after the module 10 end state wedged — see below.

## What broke

- **`create-cluster.sh` could not finish on macOS at all** (fixed `1129983`).
  `talosctl kubeconfig --force` overwrote the working kubeconfig with
  `https://10.5.0.2:6443`, an address inside the Talos docker network that
  Linux routes to and laptops do not. Every `kubectl` call blocked; nothing
  past module 01 happened. The wait loop had no `--request-timeout`, so a
  promised "2 minutes" was really ~77 minutes of frozen terminal.
- **`destroy && create` failed on the second cluster of the day** (fixed
  `3a7848f`). `talosctl config remove` refuses to remove the currently
  selected context and still exits 0; the stale context made the next create
  rename itself to `cloudbox-1` and every scripted `--context cloudbox` call
  dialled the destroyed cluster. This broke `catch-up.sh --rebuild`.
- **Node containers were capped at 2.0 CPUs each** — `talosctl`'s default,
  never overridden (fixed `33c84f7`). At module 10's end state the worker hit
  `/proc/pressure/cpu some avg10=98.72`, went `NotReady`, `kubectl` timed out
  for tens of minutes and Backstage took 9 min 03 s to Ready. Raising the caps
  mid-load with `docker update` did not rescue it cleanly; the run finished on
  the hand-repaired cluster.

## What it proved, and what it owed

It proved the platform itself fits the day: ~16 minutes of script time against
240. Both macOS blockers were invisible to `bootstrap-test.yaml` by
construction — an `ubuntu-latest` runner routes into the Talos docker network
and a Mac cannot. Owed: a cold-start run, the recovery path (`catch-up.sh`),
and proof that the CPU-cap fix holds from the start of a run rather than being
applied mid-wedge. Rehearsal 2 collected all three.

Sources: `docs/HAZARDS.md` (rehearsal summaries and the CPU-cap and
recovery-path entries), the comparison tables in `docs/REHEARSALS.md`.
