# Rehearsal 9 — aborted: tbxd panics the macOS kernel, v0.1.3 (2026-08-30, 00:24)

A rehearsal that destroyed its host is a result. This run was meant to be an
agent-driven pass over the updated lab content (PR #222,
`labs/going-deeper-tasks`, worktree `/tmp/cbx-tasks`) on tbx; it ended with
the laptop hard-resetting on a macOS kernel panic before a single module ran.

## Setup

- Host: Mac17,7, macOS 26.6.2 (25G83), Darwin 25.6.0 `xnu-12377.161.14~5`,
  128 GB — the rehearsal-8 host, **not** the rehearsal-7 machine.
- tbx v0.1.3 throughout (client; daemon protocol 17; helper protocol 5).
- Prep, 00:12–00:14 local: rehearsal 8's cluster destroyed, kubeconfig and
  substrate record cleared, `tbx doctor` 0 FAILs, `tbx mirror offline` flipped
  back ON (it had drifted off — which would have let the run pull from the
  internet and hide any pre-pull gap), and the corrected Hubble v0.13.5 images
  warmed (2 warmed, 1 already complete). Then the participant agent was
  dispatched.

## Result

| | rehearsal 9 (tbx v0.1.3) |
|---|---|
| modules reached | **0** |
| host | **kernel panic, hard reset**, 2026-08-30 00:23:56 local |
| panic | `Kernel tag check fault`, panicked task pid 74954: `tbxd`, 24 threads holding `com.apple.virtualization.thread.cpu-0..15` and `raw-disk-image-io-0..7` |
| evidence | `/Library/Logs/DiagnosticReports/panic-full-2026-08-30-002356.0002.panic` |

The panic came during cluster teardown or create — which of the two was not
captured. The reset cleared `/tmp` (taking the worktree the agent was reading
from), left the VMs `stopped` with no kubeconfig, and killed the dispatched
agent mid-run. Nothing was lost from the repo: all seven of the branch's
commits were already on origin.

## What it cost, and what came next

The whole environment, with no warning and no chance to save anything — the
failure mode that outranks every slow-cluster hazard, because an attendee
whose laptop does this has lost more than the workshop. A "kernel tag check
fault" is MTE catching a pointer-tag mismatch in *kernel* memory; userspace
cannot legitimately cause one, so this is a bug on the far side of
Virtualization.framework that tbxd provokes, not something tbx configuration
can work around.

The run was briefly re-dispatched on the same v0.1.3 before the panic file had
been read; once `tbxd` was identified as the panicked task the agent was
stopped and the leftover cluster destroyed. talos-box v0.1.4 had shipped seven
hours earlier with ballooning and guest-reclaim changes — exactly the memory
machinery such a fault could come from, circumstantially — so the obvious next
move was the upgrade. Rehearsal 10 is that move failing.

Full hazard entry: `docs/HAZARDS.md`, "tbxd can panic the macOS kernel, and
the v0.1.4 bump does not fix it" (`eb5860c`).
