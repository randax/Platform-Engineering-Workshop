# Rehearsal 15 — an outside agent on the rewritten labs (2026-08-31)

The first run against the labs, slides and docs as they will be delivered. Driven by
`agy` (the Antigravity CLI) from a handover prompt rather than by the maintainers, on
the docker substrate, on the same host that rehearsals 9, 10 and 14 kernel-panicked
under tbx. Started 23:05, finished 23:43.

## Setup

`mise run cluster:destroy` then `mise run cluster:create`, so the agent built its own
cluster rather than inheriting one. No intervention was needed.

`tbx` was uninstalled and `mise.local.toml` pinned `CLOUDBOX_SUBSTRATE=docker` and
`CLOUDBOX_IGNORE_TBX=1`, so substrate detection never entered the picture.

## Results

| | |
|---|---|
| Modules 00-09, each `./verify.sh` | **exit 0, all ten** |
| Hints used | 03, 06, 09 (one layer); 04, 07, 08 (full solution) |
| Manual interventions | none |
| Cluster at the end | both nodes Ready, 14/14 ArgoCD apps Synced and Healthy |

Independently re-verified by the maintainer after the agent reported: modules 04 and 09
re-run by hand, both green, against the same live cluster.

## What this run existed to test

The three "Going deeper" tasks were rewritten the night before from a bug report, not
from a live cluster, so nothing had confirmed the new text was accurate. All three
matched:

- **Module 08, the storage trap.** The agent reproduced the silent failure exactly: the
  portal reported success, `spec.size` said `medium`, `status.phase` said
  `Cluster in healthy state`, and `readyInstances` sat at 1 against `spec.instances: 2`,
  with `only dynamically provisioned pvc can be resized and the storageclass that
  provisions the pvc must support resize` in the operator log. Its words: "This perfectly
  matches what the text predicted step-by-step."
- **Module 07, the digest lesson.** Rebuilding `:v1` pushed a new digest to Zot while the
  cluster kept running the old bytes, because a non-`:latest` tag defaults to
  `IfNotPresent`. "Matched the text's prediction exactly."
- **Module 04, the major upgrade.** Changing `version: "17"` to `"18"` triggered the
  `-major-upgrade` job and completed in place.

## What this run does NOT tell us

Two limits worth stating, because the report reads cleaner than the evidence supports.

**The timings are not human timings.** The agent finished modules in two to ten minutes
each and marked every timebox realistic. It does not read, deliberate, mistype or get
stuck, so that column says nothing about what 40 people will do with 20 minutes.

**The one sudo in the workshop was never exercised.** The agent noted that the
`/etc/hosts` prompt "seemed to pass automatically or didn't prompt". It did not prompt
because the marked block already existed from an earlier run on the same host. The path
an attendee actually hits, a fresh machine with no block and a password prompt at the end
of `cluster:create`, is still untested.

## What it retires

The rewritten module 04, 07 and 08 "Going deeper" texts are now confirmed against a live
cluster by someone who had not read them before. That was the largest untested surface
going into delivery.
