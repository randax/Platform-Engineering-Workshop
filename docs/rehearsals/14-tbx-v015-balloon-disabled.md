# Rehearsal 14 — tbx v0.1.5 with the balloon disabled (2026-08-30)

The test upstream asked for. talos-box v0.1.5 shipped two mitigations for the
kernel panics of rehearsals 9 and 10, both aimed at the memory balloon:
`TBX_DISABLE_BALLOON=1` to launch guests with no balloon device at all, and
parking the balloon manager during VM teardown. Upstream's own guidance calls the
first "the first thing to try if the host itself panics during cluster teardown".

Same host as rehearsals 9 and 10: Mac17,7, 18 cores, 128 GB, macOS 26.6.2 (25G83).
128 GB puts it squarely in the "hosts with plenty of RAM" case upstream recommends
the setting for.

## Setup

Client, daemon and helper all on v0.1.5. The mitigation was confirmed active in two
independent places before anything was created — `tbxd.log` printing
`balloon: disabled by TBX_DISABLE_BALLOON`, and `tbx doctor` printing an
`INFO balloon` line naming #513. The workshop pins were bumped to v0.1.5 in
`scripts/versions.env` and `mise.toml` for the duration so the preflight's version
check would pass, and reverted afterwards.

## What happened

| | |
|---|---|
| `TBX_DISABLE_BALLOON=1 tbx system restart` | 23:33:48, tbxd pid 62502 |
| `create-cluster.sh` — VMs, config, bootstrap, Cilium, both nodes Ready, VIP | **4 min 40 s** |
| `bootstrap-gitops.sh` + `seed-gitea.sh` | 78 s combined |
| lab 01 `verify.sh` | exit 0 |
| lab 00 and lab 02 `verify.sh` | exit 1, both false — see below |
| `destroy-cluster.sh` | 12 s, reported success, `No clusters` |
| **kernel panic** | **23:44:05, 71 s after teardown reported success** |

The cluster itself was fine. It came up cleanly, ran a real GitOps stack, and tore
down without complaint. The host panicked afterwards, while the VM objects and
their network attachments were being released in the background.

Both `verify.sh` failures were artifacts of the session, not the workshop, and are
recorded here so nobody chases them. Lab 00 reported `host memory: 0 GB` because
`sysctl` is not on `PATH` in the agent's tool shell; with `/usr/sbin` on `PATH` it
reads 128 GB and exits 0. Lab 02 reported ArgoCD app `demo` missing, which is
correct — lab 02 had not been done on this cluster, and the fresh-clone invariant
says `gitops/apps/` carries only `local-path-provisioner.yaml`.

## What it proves

The balloon is not the cause. With the KASLR slide removed, all three panics are
the same instruction: pc offset `0x4698e4`, caller offset `0x9a1da8`,
`esr 0x96000011` (a synchronous tag check fault), `far` at `+0x28` of a tagged
object. That is identical across v0.1.3 (balloon on), v0.1.4 (balloon on) and
v0.1.5 (balloon off), so neither of v0.1.5's mitigations touches whatever is
faulting.

It also sharpens the pattern: the panic fires around **VM lifecycle transitions**,
never in steady state. Rehearsal 10 panicked 58 seconds into a create; this one 71
seconds after a teardown returned. A cluster that is merely running has never been
the problem.

Posted to upstream #513 with the normalized offsets, the backtrace and the daemon
log, as evidence against that issue's own hypothesis 1 and for its hypothesis 2
(the `FileHandleNetworkDeviceAttachment` vmnet path).

## What it cost, and what it changes

One host reset, and the pin bump was reverted: `TBX_VERSION` stays `v0.1.4`,
because a version that panics the rehearsal host is not one to ship to attendees,
and v0.1.5 has no advantage over v0.1.4 for us if neither works here.

The lesson worth keeping is the shape of the failure rather than the version
number. **Everything worked and the machine still died a minute later.** A
rehearsal that ends green is not evidence of a substrate that is safe; only the
minute after it ends is. On the day this is worse than failing loudly, because an
attendee would see a healthy cluster and then lose the laptop under it.

Three released versions have now been tried on this host. "Bump it and see" is
spent as a strategy; the next thing worth testing is an alternative network
attachment, not another release.
