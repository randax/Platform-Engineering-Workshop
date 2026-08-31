# Rehearsal 10, aborted: the v0.1.4 upgrade does not fix it (2026-08-30, 00:42)

Seventeen minutes and thirty-nine seconds after rehearsal 9's panic, the same
host panicked again, this time on a fully upgraded talos-box v0.1.4, one
minute into a supervised `create-cluster.sh`. This is the run that spent the
obvious remedy, which is the whole point of recording it.

## Setup

- Same host as rehearsal 9 (Mac17,7, 128 GB, macOS 26.6.2).
- Full upgrade first, 00:33–00:38 local, per the `docs/MAINTENANCE.md`
  runbook: client v0.1.3 → **v0.1.4**, daemon restarted (protocol 17 → 20,
  pid 29587), and the privileged helper deliberately aligned to v0.1.4 too;
  it was still protocol-compatible at v0.1.3, but rehearsing on a mismatched
  helper rehearses something no attendee will have. `tbx doctor`: 0 FAILs,
  exit 0. Both repo pins (`scripts/versions.env`, `mise.toml`) bumped in one
  edit; `check-consistency.sh` agreed.
- Deliberately supervised: no participant agent until v0.1.4 had proven it
  could create a cluster on this host. `create-cluster.sh` launched 00:40:37
  local.

## Result

| | rehearsal 10 (tbx v0.1.4) |
|---|---|
| modules reached | **0** |
| host | **second kernel panic, hard reset**, 2026-08-30 00:41:35 local, 58 s after the create launched |
| panic | same `Kernel tag check fault`, same register fingerprint (`x2=0x13e`, `x5=0x3a980`), different KASLR slide; panicked task pid 29587: `tbxd`, the v0.1.4 daemon, 18 threads |
| evidence | `/Library/Logs/DiagnosticReports/panic-full-2026-08-30-004135.0002.panic` |

## What it retired, what it found on the way, what came next

**Retired: "upgrade tbx" as the remedy.** Two identical panics, 18 minutes
apart, one on each release. The fix is upstream of tbx, on the far side of
Virtualization.framework, and no tbx version choice reaches it. Filed
upstream, with a sanitized `.panic` file (checked twice for anything
non-technical before sending).

Found during the upgrade itself, cheap but real: v0.1.4's doctor WARNs that
two tbx installs exist on a clean mise setup: it counts the shim and its
resolved binary separately, so every mise-installed attendee will see that
WARN. Doctor still exits 0 despite it, so substrate detection is unaffected.
And the Talos pin holds through the bump: the cluster template writes
`talos.version: v1.13.8` explicitly, so v0.1.4's new v1.13.9 default never
applies and the cached disk image stayed valid.

**Aftermath.** tbx was uninstalled from this host rather than fought: helper
booted out (`launchctl bootout`, plist removed), binaries and shims removed,
213 MB of partial-create wreckage cleaned, the 5.4 GB image cache kept (inert
without the binary, expensive to re-warm). `substrate-decide.sh` then picks
docker on its own, the fallback working as designed, no repo change. The
v0.1.4 pin was committed anyway (`69bc59d`): v0.1.3 panics identically, so
v0.1.4 is still the better pin wherever tbx is used. The default stays tbx
because rehearsal 7 ran the whole workshop clean on it the same week on
another machine; the sample is two hosts, and what differs between them is
exactly what is unknown. The hazard entry (`docs/HAZARDS.md`, `eb5860c`)
carries the on-the-day rule: one panicked attendee goes to docker; a second
flips the default for the room.

Rehearsals 11 and 12 are this host continuing the night on the docker
substrate.
