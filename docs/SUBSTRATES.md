# Substrates: Docker, tbx, and kind

The [README](../README.md#get-started) says which substrate you get in a paragraph.
This is the rest of it.

Whether talos-box should replace Talos-in-Docker at all is a separate question, answered
in [talos-box-vs-docker.md](talos-box-vs-docker.md).

Every module after 01 is identical on both substrates: same labs, same `verify.sh` scripts,
same URLs.

| | **Docker** (Talos-in-Docker) | **tbx** (real Talos VMs) |
|---|---|---|
| Who gets it | everyone by default | Apple Silicon macOS, or Linux with KVM, **and** only if you install the helper below |
| Extra setup | none beyond Docker itself | one privileged install, once |
| Needs Docker | yes | **no**, not at all |
| Force it | `CLOUDBOX_SUBSTRATE=docker` | `CLOUDBOX_SUBSTRATE=tbx` |

`mise run preflight` prints which one you will get and, on a fallback to Docker, the
`tbx doctor` line that decided. The `mise.local.toml` pin ([Get started](../README.md#get-started)) is
gitignored and outranks both a shell prefix and an exported variable, so it sticks until you
delete the line. Keep it out of the shared `mise.toml`: a value there would silently beat
every `CLOUDBOX_SUBSTRATE=…` anyone types, including yours.

**The override picks; it does not overrule what is already there.** Once a cluster exists,
`~/.cloudbox/substrate` is a *record*, not a preference: `create-cluster.sh`,
`destroy-cluster.sh`, `kind-fallback.sh`, `--refresh-endpoint` and
`install.sh --write-hosts`/`--add-hosts` all refuse, before touching anything, when the
substrate you ask for is not the recorded one. With no record (a fresh laptop, CI) the
override is simply the answer. Changing substrates is two commands and they say so:

```bash
CLOUDBOX_SUBSTRATE=tbx mise run cluster:destroy       # (or ./scripts/kind-fallback.sh --delete)
CLOUDBOX_SUBSTRATE=docker mise run cluster:create
```

The record lasts as long as the cluster: `destroy-cluster.sh` removes the file and the next
`create-cluster.sh` decides afresh, printing the substrate it just forgot and the command
that keeps it (`CLOUDBOX_SUBSTRATE=<what it was> ./scripts/create-cluster.sh`), worth using
if you chose deliberately, because detection will not know you did.
`catch-up.sh <module> --rebuild` carries it across for you.

**Half-installed tbx.** If `tbx` is on your PATH but its helper daemon is not running, the
docker path cannot ask it whether a `cloudbox` cluster exists there. It continues anyway
when this machine carries no trace of one (`~/.cloudbox/substrate`,
`~/.cloudbox/cloudbox.tbx.yaml` and `~/.talosbox/clusters/cloudbox` all absent); with a
trace present it stops rather than risk two clusters of the same name: fix tbx, or set
`CLOUDBOX_IGNORE_TBX=1` if you know those VMs are down.

**One catalog extra is amd64-only:** Backstage's CNOE image has no arm64 build, and a tbx VM
emulates nothing, so on Apple Silicon that stretch item needs the Docker substrate.
`install.sh --check` warns. Nothing on the core path is affected.

## Real Talos VMs with tbx

Step 1 already installed the `tbx` **binary** (pinned in `mise.toml`). Only you can install
its privileged helper:

```bash
tbx system install && tbx doctor    # macOS: asks for your password itself
```

"exit 0, no FAIL" is the bar. Skip this entirely and nothing breaks: `tbx doctor` fails and
the scripts put you on Talos-in-Docker, which runs the same workshop. Two rules: never run
`sudo tbx …`, because sudo's PATH may find a different tbx than yours (`tbx system install`
elevates itself; if you truly must, `sudo "$(command -v tbx)"`); and keep exactly one
tbx/tbxd/tbx-helper triad on PATH, or `tbx doctor` warns. A Homebrew `randax/tap/tbx` exists
but is not pinned, so mise stays the supported route.

On **Linux with KVM**, mise ships the three binaries but there is no `system install`: the
helper is a systemd unit set that talos-box's `docs/linux.md` installs from a source
checkout. Check out the tag pinned as `TBX_VERSION` in `scripts/versions.env` so daemon and
helper match the pinned client.

> **Before you install the helper, read this.** On one rehearsal machine tbx caused a
> **macOS kernel panic** (a hard reset with no warning) three times, on three tbx versions.
> Upstream traced it to a bug in XNU's socket content filter, not tbx itself, needing three
> ingredients together: a **content-filter network extension** (Little Snitch, some VPN or
> endpoint-security products), **recent Apple silicon**, and a socket-busy process. Other
> machines run tbx all day without trouble, so it stays supported and the default where
> `tbx doctor` passes. If you run a content filter and would rather not gamble your laptop,
> skip the helper and use Docker. Details and current state in
> [`docs/HAZARDS.md`](HAZARDS.md).

**tbx on macOS can run its VMs on two hypervisors** (tbx ≥ v0.1.6). The default is Apple's
Virtualization.framework (`vz`): zero install, leave it alone if it works. If
Virtualization.framework itself misbehaves on your machine, QEMU/HVF is the escape hatch:

```bash
brew install qemu     # macOS 15+ — on macOS 14 Homebrew builds QEMU without HVF
CLOUDBOX_TBX_HYPERVISOR=qemu mise run cluster:create
```

The choice is baked into the cluster at creation and is **immutable**: to move an existing
cluster to the other hypervisor, `mise run cluster:destroy` first, then create with the
override. Same labs, same URLs, same mirror on either backend. One honest caveat: the
kernel-panic hazard above is a content-filter bug in macOS itself and is *not* avoided by
switching to QEMU; for that, deactivate the content-filter extension or use the Docker
substrate.

## Hostnames on the Docker substrate

Docker has no resolver, so the workshop hostnames come from a marked `# cloudbox-begin`
block in `/etc/hosts`, written via `sudo tee` at the end of `mise run cluster:create`;
`./scripts/install.sh --print-hosts` shows exactly what goes in (WSL2: the same lines also
belong in `C:\Windows\System32\drivers\etc\hosts`, edited as Administrator). Decline the
password and every `*.cloudbox.k8s.test` URL fails on a perfectly healthy cluster; the
cluster stays up, and `./scripts/install.sh --write-hosts` writes the block whenever you are
ready. That is also the fix when the names stop resolving: **WSL2 rewrites `/etc/hosts`
on every restart** unless you tell it not to, and its file and the Windows one are
independent — neither seeds the other (see `lab/00-setup`). *Every*
`mise run cluster:destroy` on the Docker substrate *asks* to remove the block, not only
`--purge-mirror`, which also forgets the extra names you added with `--add-hosts`;
decline that prompt and the teardown still finishes, saying which lines remain. On tbx
nothing touches `/etc/hosts`; talos-box's own resolver answers the names.

## The kind lifeboat

`mise run cluster:fallback` gives you a kind+Cilium cluster meeting the same contract: the
same vendored Cilium with the **same ingress values**, host port 80 mapped to the ingress,
and the same marked `/etc/hosts` block, so every `*.cloudbox.k8s.test` hostname works and
**modules 02 onward are identical**. You lose only the Talos content of module 01:
`lab/01-cluster/verify.sh` checks a Talos cluster, so on the lifeboat it prints "not
gradeable here" and exits 0 rather than failing a cluster that is working as documented.

kind is not one of the two substrates, but it *is* a recorded identity: the script writes
`kind` into `~/.cloudbox/substrate`, which tells `install.sh --check` to grade this machine
with Docker semantics, fills the image mirror for the right architecture, and makes
`create-cluster.sh` and `destroy-cluster.sh` **refuse** rather than build a second cluster
over the lifeboat or delete its hostnames.

Tear the lifeboat down with `./scripts/kind-fallback.sh --delete`: it deletes the kind
cluster, removes the `/etc/hosts` block it wrote (one sudo prompt; decline and it names the
lines to delete by hand) and clears the identity. It removes the block only when the
identity says `kind`, so on a Docker-substrate machine it cannot take out a live cluster's
names; and it clears the identity only once the cluster is gone *and* the block is removed
or proven absent, so a declined sudo leaves you able to retry. If the file is missing (a
lifeboat taken before this existed), say so for the session:
`CLOUDBOX_SUBSTRATE=kind mise run preflight`. The same override works for the teardown,
`CLOUDBOX_SUBSTRATE=kind ./scripts/kind-fallback.sh --delete`, but there it is honoured only
against **kind-specific** proof: `kind get clusters` must list `cloudbox`, or Docker must
still hold containers labelled `io.x-k8s.kind.cluster=cloudbox`. The `/etc/hosts` block is
*not* proof: the docker substrate writes an identical one, and accepting it would let an
environment variable delete a live Talos cluster's hostnames. Once proved, `kind` is written
back into `~/.cloudbox/substrate` immediately, so a retry after a declined sudo needs no
override at all. The teardown exits non-zero whenever anything is left; it needs Docker
running (it asks the daemon for the containers) but neither `kind` nor `kubectl` on `PATH`.

## The offline story

The offline guarantee, on both substrates, is a registry mirror the nodes pull through: on
the Docker path a `cloudbox-mirror` container on port 5001, on the tbx path talos-box's own
mirror (`tbx cache warm` fills `~/.talosbox/cache` and tbxd serves it to the VMs at the
cluster gateway). On tbx, step 2 also warms the Talos disk image (`tbx cache pull`, 95 MB on
arm64, 204 MB on amd64); step 3 asserts a complete `disk.raw` is in `~/.talosbox/cache` and
grades the images with `tbx cache warm --check` (use `--check --deep` before you travel). At
the venue, `tbx mirror offline on` stops tbx's mirror fetching upstream, so a missing image
surfaces as a mirror miss rather than being quietly filled over the WiFi; the nodes keep
`skipFallback: false`, so the pull then goes direct, slowly and visibly.

One trade-off: tbx's store serves VMs only, so on a tbx laptop the Talos-in-Docker fallback
is **not** offline-ready unless you also run `CLOUDBOX_SUBSTRATE=docker mise run init` at
home (needs Docker, ~7.5 GB more).

## Your kubeconfig

Step 1 offers to hook [mise](https://mise.jdx.dev/) into your shell. **Say yes.** Besides
putting the pinned tools on your PATH, it makes `KUBECONFIG` point at
**`~/.kube/cloudbox.conf`** while you are inside this repo: this workshop's cluster and
nothing else, so tearing it down leaves nothing for `kubectl` to silently fall through to,
and your own contexts are never modified. `echo $KUBECONFIG` shows which file you are on.
Decline and everything lands in `~/.kube/config` as it always did; the workshop still works,
and the scripts refuse to touch a non-workshop context either way. Just don't do half of
each: scripts through `mise run` / `mise exec` plus bare `kubectl` in a shell that never got
the pin puts your cluster and your terminal on two different files.
`./scripts/install.sh --check` tells you which side you are on.

## Hardware

| | tbx (real Talos VMs) | Docker (Talos-in-Docker) |
|---|---|---|
| Minimum | 16 GB RAM, 4 cores, 40 GB free | 16 GB RAM with **≥10 GB and ≥4 CPUs to Docker**, 40 GB free |
| Comfortable | 32 GB | 32 GB |
| What you get | real `LoadBalancer` VIPs, a real L2 segment | the same labs, the same URLs, via published ports |

The full platform idles at roughly 8 GB inside the cluster; 16 GB machines fit, but close
your Electron zoo. On Docker: OrbStack, or a Docker Desktop with a raised memory limit; WSL2
users raise it in `.wslconfig`. On tbx the VM sizes are pins (`TBX_CP_MEMORY` /
`TBX_WORKER_MEMORY` in `scripts/versions.env`): a boot ceiling, not a permanent reservation.
talos-box balloons memory back out of a running node when the host comes under pressure,
which keeps the laptop alive and means a hungry browser can shrink your cluster mid-module.
Close the zoo anyway.

## Platform support matrix

16 GB RAM, 4 cores and 40 GB free is the floor on both substrates (on Docker, with at
least 10 GB and 4 CPUs given to Docker itself); 32 GB is comfortable, and the full
platform idles at roughly 8 GB inside the cluster. Details, and what each substrate buys
you, are in [Hardware](#hardware) below.

| Platform | Substrate | Support |
|---|---|---|
| macOS, Apple Silicon | tbx (Docker if `tbx doctor` fails) | fully supported |
| Linux, amd64/arm64 with KVM | tbx (Docker if `tbx doctor` fails) | fully supported |
| macOS, Intel | Docker | fully supported |
| Windows via WSL2 | Docker | best-effort; pair up if it fights you |
| GitHub Codespaces / devcontainer | Docker | the lifeboat, tested weekly in CI |

On Linux, watch out for firewalld/nftables interference on either substrate.
