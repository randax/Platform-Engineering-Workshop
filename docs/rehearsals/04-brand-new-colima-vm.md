# Rehearsal 4: a brand-new Colima VM, twice through (2026-08-18)

The from-nothing proof: a Colima instance created minutes before the run, with
0 images, 0 containers and 0 volumes, and the eleven modules passed **twice**:
once forward, once on the cluster `catch-up.sh 10 --rebuild` built. That was
the first successful `--rebuild` in four attempts.

## Setup

- Substrate: Talos-in-Docker, on a freshly created Colima VM (8 CPU / ~16 GiB
  host, same laptop as rehearsals 1–3).
- Mirror: cold, everything from zero.

## Results

| | rehearsal 4 |
|---|---|
| modules | 00→10, **11/11 `verify.sh` exit 0, twice** (forward, then on the `--rebuild` cluster) |
| total script time | **~28 min** |
| `cloudbox-init.sh` | one 13:39 pass, 7.87 GB, 66/66 refs, **0 retries** |
| module 00 | all-green for the first time since rehearsal 2 (92 GB free against the 40 GB gate) |
| blockers found | **2, both in the recovery path** (`218a248`, `87231be`); one introduced by us fifteen minutes before the run |
| open MAJOR | the portal roll-status bug, since fixed and released (`024421e`, `cloudbox-portal:v0.2.2`) |

## What broke

- **A deleted Docker VM left a Talos state directory nothing removed** (fixed
  `218a248`): `create-cluster.sh` died in 2 s, `destroy-cluster.sh` said
  "nothing to destroy" and exited 0. An infinite create→destroy→create loop
  at module 01, found in the first two seconds of the run.
- **Every fresh clone of the platform repo was an untrusted mise config**
  (fixed `87231be` + `f64d319`): every mise-installed tool run from inside a
  clone exited 0 with empty output, and `catch-up.sh` `cd`'d into one. We
  introduced this ourselves in `e292e25`, fifteen minutes before the run
  started. The `KUBECONFIG` pin was individually correct, reviewed, and
  shipped with tests, and it broke a path nothing tested.

## What it proved

The full cold path, end to end, twice, on a machine with no history: pre-pull
in one pass with zero retries, the recovery build finally green, and the
rehearsal-3 context fix retired on a real multi-context kubeconfig. It also
supplied the two lessons the analysis in `docs/REHEARSALS.md` closes on: a fix
can be a regression, and summarising is where the errors enter.

Sources: `docs/HAZARDS.md` (rehearsal summaries and the two recovery-path
entries), `docs/REHEARSALS.md` (tables and the two rehearsal-4 lessons).
