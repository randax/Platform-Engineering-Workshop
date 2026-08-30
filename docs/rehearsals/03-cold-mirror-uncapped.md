# Rehearsal 3 — cold mirror, uncapped nodes (2026-08-17 evening → 08-18 morning)

The same workshop as rehearsal 2 with the node CPU caps removed — the
difference between their script times (~32 vs ~24 min) is the single biggest
lever in the comparison table. Same Apple Silicon + Colima laptop.

## Setup

- Substrate: Talos-in-Docker, Colima (8 CPU / ~16 GiB).
- Mirror: cold.
- Node containers uncapped (the `33c84f7` fix in effect from the start).

## Results

| | rehearsal 3 |
|---|---|
| modules | **10/11** — module 00 red on the laptop's own free disk, everything else green |
| total script time | **~24 min** |

## What it found

The two findings that changed the most code of any rehearsal:

- **The context near-miss**: workshop scripts grading a **36-node corporate
  cluster** — the attendee's real kubeconfig, not the workshop's. Closed in
  `2b8de71` (lab/) and `b4f5e2d` (scripts/ + solutions/), with the residual
  retired in rehearsal 4, which re-ran rehearsal 3's actual sequence after the
  fix on a laptop with a real multi-context kubeconfig.
- **A module 10 beat 1 that drove the machine into a cluster-wide liveness
  cascade**, which is what moved the kagent model pin.

Module 00's red was the 40 GB free-disk gate doing its job against the
laptop's actual disk, not a workshop bug.

## What it proved

That the caps were the bottleneck (the ~8 minutes back against rehearsal 2),
and that the platform repeats itself: same Cilium, same Kourier port pattern,
same RustFS log-rate numbers as the runs before it. What kept moving was the
setup and recovery surface — rehearsal 3's worst finding sat on the
post-destroy path, the same blind spot as rehearsals 1, 2 and 4.

Sources: `docs/HAZARDS.md` (rehearsal summaries, the kubeconfig-context
entries), the comparison table in `docs/REHEARSALS.md`.
