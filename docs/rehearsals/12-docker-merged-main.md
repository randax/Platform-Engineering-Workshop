# Rehearsal 12 — the rewritten content held to its word, on merged main (2026-08-30, ~08:00–09:32)

The morning-after run: PR #222 merged, and a fresh participant agent pointed
at latest `main` (`/tmp/cbx-run2` @ `c9325f9`, detached HEAD) on the docker
substrate, specifically to hold rehearsal 11's rewritten going-deeper texts to
their own sentences. Its record is `~/workshop-run2-report.md`; the one fix it
forced is `bacbd4d`.

## Setup

- Substrate: docker, forced via `CLOUDBOX_SUBSTRATE=docker`. colima, 4 CPU /
  12 GiB — deliberately the published floor, on the 128 GB host.
- Mirror: warm. Roughly a 65-minute run, dispatched ~08:00 local, report's
  last write 09:32.

## Results

| | rehearsal 12 (docker, main @ `c9325f9`) |
|---|---|
| modules | 00–09 plus module 10 scenario 1 — **all eleven `verify.sh` runs exit 0** |
| skipped, reported as skipped | module 05 faults 2/3, module 10 scenarios 2/3 (time) |
| `create-cluster.sh --skip-cilium` | **~85 s**; Cilium ~25 s from helm returning to both nodes Ready; under 2 min total, zero interventions |
| memory | no OOMKilled, no Evicted, no NotReady; worker peak **4.95 GiB / 6 GiB (82.5%)** moving in a 4.0–4.95 GiB band, control plane 3.08–3.17 / 4 GiB |

The rehearsal-11 curl artifact did not recur — the `-4` fix held, and none of
the documented docker/tbx failure modes fired.

## The three rewritten going-deeper tasks, verdict

- **Module 04 (Postgres 17→18)**: matches reality; `psql` genuinely flipped
  `PostgreSQL 17.6` → `18.4`. One soft spot: the upgrade Job's window is under
  ~20 s, shorter than "watch the Job and read its logs" implies.
- **Module 07 (rebuild the same `:v1` tag)**: matches exactly — same tag, new
  digest, running pod provably pinned to the old one. The cleanest of the
  three.
- **Module 08 (resize on `local-path`)**: matches sentence by sentence,
  including two verbatim error strings, and all three claimed lies confirmed
  simultaneously (form 200, `spec.size=medium`, "Cluster in healthy state").
  **And one thing the text did not warn about: lab 08's own `verify.sh` was
  fooled by the exact same lying `status.phase`** — re-run mid-stall it
  reported a clean exit 0, reassuring the participant with the tool the lesson
  says not to trust. Fixed the same morning (`bacbd4d`).

## Other findings

- **Adventure Door 3 Arc 1 is real**: the enforcing `ingress: [{}]` /
  `egress: [{}]` form broke the picture pipeline for real, and Hubble showed
  244 DROPPED flows in ~2 s, DNS egress drops included. One trap the doc
  omits: `kubectl exec ds/cilium` picks an arbitrary agent — on this 2-node
  cluster it first picked the control-plane agent, which is blind to the
  `pipeline` namespace's traffic.
- The Console's Billing page undercounted live databases (2 shown, 3 running
  — plausibly counting XRs, since module 03's `app-db` bypasses the platform
  API); the "Functions" nav label routes to `/services`, so a hand-typed URL
  404s; module 06's "0 → 1 → 0" understates that a fresh ksvc starts with a
  pod already running; module 09's cold-start estimate is written for a colder
  cache than prework leaves (~3.4 s observed).
- **The memory floor holds, with the margin spent**: at the published floor,
  the heaviest legitimate state (everything through module 09 plus full
  observability) sits at 82–87% of the worker's cap with nothing else on the
  machine. Not a failure — a laptop at exactly the floor doing exactly what
  the workshop asks, with no slack to spare.

## Verdict

The report's own closing answer to "could I rebuild and change this on my own
hardware next week?" is yes: zero internet after prework, zero manual patches,
and the rewritten failure-mode texts held word for word — evidence the authors
ran the failures rather than reasoning about them. The one caution it carries
forward is memory at the floor.
