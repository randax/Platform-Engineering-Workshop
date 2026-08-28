# Known hazards

Everything we know is dangerous, deliberately weird, or unproven — with what
would go wrong, how you would notice, and what retires it.

Written during the pre-event bump pass on **2026-08-11**, three weeks before the
workshop (JavaZone, Sept 2–3), and rewritten after **four** full end-to-end
rehearsals on **2026-08-17/18**, all on the same Apple Silicon laptop
(Colima, 8 CPU / ~16 GiB, Talos v1.13.8 / Kubernetes v1.36.2 / containerd 2.2.6).
`docs/REHEARSALS.md` carries the timing envelope those runs produced; this file
carries what they taught us to be afraid of:

- **Rehearsal 1** (morning, warm mirror, one cluster): modules 00→10, **11/11
  `verify.sh` exit 0**, 21/21 ArgoCD Applications Synced+Healthy, **~16 minutes of
  script time** against the 240-minute budget. It found three blockers, two of which
  no CI job we have can see — and it ended on a cluster whose node CPU caps had been
  raised by hand after the module 10 end state wedged.
- **Rehearsal 2** (evening, **cold start** — cluster *and* mirror destroyed first, the
  full 7.25 GB pre-pull re-run from nothing): modules 00→10 again, **11/11
  `verify.sh` exit 0 on two clusters**, the second one built by
  `catch-up.sh 10 --rebuild` — the recovery path — and **~32 minutes of script time**,
  still against 240. It found four more bugs — one of them a blocker, and again in the
  place CI cannot look — all four fixed the same evening (`1f12353`, `ca4859e`,
  `92aac7a`, `4e2817b`).
- **Rehearsal 3** (2026-08-17 evening into the morning of 2026-08-18, cold mirror,
  uncapped nodes): **10/11**, ~24 minutes of script time — module 00 red on the
  laptop's own free disk, everything else green. It produced the two findings that
  changed the most code since: the context near-miss below (workshop scripts grading
  a **36-node corporate cluster**) and a beat 1 that drove the machine into a
  cluster-wide liveness cascade, which is what moved the kagent model pin.
- **Rehearsal 4** (2026-08-18, **a brand-new Colima VM** — 0 images, 0 containers,
  0 volumes at the start): modules 00→10 with **11/11 `verify.sh` exit 0, twice** —
  the forward path, and again on the cluster `catch-up.sh 10 --rebuild` built from
  nothing — in **~28 minutes of script time**. `cloudbox-init.sh` in one 13:39 pass,
  7.87 GB, 66/66 refs, **0 retries**; module 00 all-green for the first time since
  rehearsal 2 (92 GB free against the 40 GB gate). It found **two more blockers,
  both in the recovery path** (`218a248`, `87231be`) — one of them introduced by us
  fifteen minutes before the run started — and one open MAJOR that has since been
  fixed and released (`024421e`, `cloudbox-portal:v0.2.2`).

The extra ~16 minutes is coverage, not regression: s5cmd's in-cluster pod branch
(+1:30 module 03, +1:09 module 04, +1:47 module 09), deliberately longer settle
windows in module 05, and a module 10 whose scenarios 2 and 3 now produce real
symptoms and whose agent investigation actually runs. The machine is still not the
constraint. `docs/MAINTENANCE.md` is how pins get bumped; this is what to be afraid
of while doing it.

All four runs landed inside two calendar days, so **rehearsal numbers are used
below** rather than dates, wherever it matters which one a number came from.

Status key: **LIVE** = a real risk today · **WATCH** = unproven, needs a
rehearsal to settle · **PROVEN ONCE** = came out green in a rehearsal, on one
machine, one architecture — settled, not proven; several rows below are now
four-for-four, and the machine count is still one ·
**RESOLVED** = was a real hazard, is fixed, and the entry is kept because the next
person needs the history ·
**TRAP** = looks like a bug, is deliberate, do not "fix"

---

The seven entries below arrived with the **talos-box substrate** on 2026-08-24/25
(`docs/talos-box-vs-docker.md`) and share one property: **no rehearsal has run on
that substrate yet.** Everything above and below them was learned on
Talos-in-Docker, which is still what CI and the lifeboat run.

## TRAP — Backstage is amd64-only, and a tbx VM emulates nothing

`ghcr.io/cnoe-io/backstage-app` is published as a bare `linux/amd64` manifest. The
exemption that lets it past the mirror's architecture check
(`MIRROR_ARCH_EXEMPT`, `scripts/versions.env`) was written with Docker-only
evidence — "Apple Silicon runs it emulated" — which is true of Docker
Desktop/OrbStack and **not** of the tbx substrate: those nodes are natively
virtualised arm64 VMs with no emulation layer, so the pod crashloops with
`exec format error`.

**Checked before keeping the pin:** every one of the 43 tags in that repository
was a single amd64 manifest on 2026-08-25 (`crane manifest` + `crane config` over
the full `crane ls` output — no manifest list, no arm64 image anywhere). There is
nothing to re-pin to, so the pin stays and the limitation is stated instead:
`install.sh --check` warns on tbx+arm64, `gitops/catalog/backstage.yaml`'s header
says it, lab 00 and lab 08's presenter note say it, and the README's matrix says
it. Backstage is a stretch catalog item and a presenter demo; no core module
touches it, and on the docker substrate it behaves exactly as before.

**Retired by:** a multi-arch CNOE image (re-check with the same `crane` sweep at
pin-bump time), or dropping the component.

## TRAP — on Linux, `tbx doctor` at v0.1.1 can call a permission problem a FAIL

Detection gates on `tbx doctor`'s exit code (`substrate_detect`, `scripts/lib.sh`),
which is the right gate — but at the **pinned v0.1.1** one Linux check answers the
wrong question. `linuxBridgeNetfilterFinding` (`cmd/tbx/doctor_platform_linux.go`
at the tag) runs `iptables -S FORWARD` when `br_netfilter` is active, and turns
*any* error from it into `FAIL inspect FORWARD policy: exit status 4` — exit 4
being what an unprivileged `iptables` returns when it cannot talk to the kernel.
"I could not look" is reported as "I looked and it is broken".

The blast radius is small and self-healing: the FAIL makes detection fall back to
the docker substrate, which runs the identical workshop. That is why the README's
matrix now calls Linux+tbx **best-effort at v0.1.1** rather than fully supported.
The workaround, for someone who has checked their FORWARD policy themselves
(`sudo iptables -S FORWARD`): force the substrate with `CLOUDBOX_SUBSTRATE=tbx`
(plus `CLOUDBOX_ALLOW_TBX_DRIFT=1` if their tbx is newer than the pin).

**Retired by:** a tbx release containing upstream `053aecb`, which makes that
check WARN with a sudo remediation instead of FAIL. `docs/MAINTENANCE.md`'s tbx
pin section says to re-pin when one exists.

## LIVE — tbx VM memory is a moving ceiling, and it is unrehearsed

New on **2026-08-24** with the talos-box substrate (`docs/talos-box-vs-docker.md`,
decision note at the top). Everything the four rehearsals measured was measured on
Talos-in-Docker, where a node's memory limit is *soft* in the attendee's favour: the
container shares the host's page cache, and `--memory-workers` is a cgroup ceiling the
host quietly pads.

**The same 6 GiB reserve is also a hard admission gate, and it nearly shipped as "tbx
does not work on a 16 GB Mac".** `tbx up` does not merely warn about overcommit — it
**errors** when planned VM memory exceeds host RAM minus that reserve, unless you pass
`-force` (upstream `internal/daemon/balloon.go:174-202`, reserve default
`internal/balloon/manager.go:108-119`). A 16 GB Mac is 16384 MiB, so the budget is
**10240 MiB**, and the flat `4GiB + 8GiB = 12288 MiB` pair exceeded it on **every machine
at the published minimum spec**. Nothing in the workshop would have started; the review
that caught it was reading upstream, not running it.

The fix is to size the worker to the host at render time, the mirror image of what we
already do to worker vCPUs: `worker_gib = clamp(host_gib − 6 − cp_gib, 4, TBX_WORKER_MEMORY)`
(`tbx_worker_memory()` in `scripts/substrate/tbx.sh`, host RAM from `sysctl hw.memsize` /
`/proc/meminfo` — the same sources tbxd reads). 16 GB → 4+6, fitting the budget exactly;
24 GB and up → the full 4+8. We deliberately do **not** pass `-force`: silencing a memory
gate on the machine that is about to run 21 apps is how a laptop swaps itself to death in
front of a room. Note the gate is **macOS-only** upstream — `HostTotalMiB` has no Linux
implementation (`internal/balloon/hostmem_stub.go`), so `checkOvercommit` stands down
there; we scale on Linux anyway, because fitting the host is right on both.

A VM's memory is soft in the *other* direction. `TBX_CP_MEMORY="4GiB"` and
`TBX_WORKER_MEMORY="8GiB"` (`scripts/versions.env`, the latter now a **ceiling**) are the
sizes the guest kernel boots with, but `tbxd` runs an **active balloon manager**: on macOS it samples host memory
pressure and inflates the guests' virtio balloons when host free memory drops below a
**6 GiB reserve**, taking memory back from a running node down to a **1 GiB per-node
floor**, and deflating on release (upstream `docs/SPEC.md:319-328` and the closed G3 gate
at `:595-600`; the Linux host-free sampler is not implemented yet, so the policy is
presently inactive there). We opt into it deliberately — `substrate_create()` patches
`machine.kernel.modules: [virtio_balloon]` into the guests
(the `balloon_patch` in `substrate_create()`, `scripts/substrate/tbx.sh:313-319`), because without the module loaded the balloon device
is inert and the overcommit story stops working.

That makes the OOM hazard **worse on a busy laptop, not better**: a node can *lose* memory
mid-module because Slack and Chrome got hungry, rather than merely starting out too small.
And the starting sizes are guesses — the CP matches the docker substrate
(`TALOS_MEMORY_CONTROLPLANE="4096"` ↔ `4GiB`) while the worker is now whatever the host
allows up to `8GiB`, i.e. **`6GiB` on exactly the 16 GB machines the minimum spec
publishes** (the docker substrate gives those a 6144 MiB worker too, so this is parity,
not a regression) and `8GiB` above that — against a module-10 end state of 21 ArgoCD apps
and 66–73 pods that has never been run inside a VM. Two unmeasured things, not one: the
size, and what the balloon does to it.

**How you would notice.** Pods OOMKilled, or the kubelet evicting, on a laptop where the
docker substrate sails through the same module — the giveaway is `docker` working and
`tbx` not on the *same* machine. If it happens *mid-module* rather than at the start,
suspect the balloon and check host pressure (`tbx doctor`'s `host-pressure` line prints
the three numbers it decided on). Watch modules 08–10, where the pod count peaks.

**Retired by:** the tbx rehearsal measuring peak node RSS at the module-10 end state and
the measured numbers landing in `scripts/versions.env` (up, or down) — ideally on a laptop
with the usual conference-day tab collection open, since an idle-host measurement says
nothing about what the balloon will do at the venue.

## LIVE — L2 failover on macOS takes 40-50 s

Cilium announces the ingress VIP over L2 (`scripts/substrate/lb-objects.tbx.yaml.tmpl`,
applied by `substrate_post_cni()` in `scripts/substrate/tbx.sh:525-543`). When the node
holding the VIP goes away, the new announcer sends a gratuitous ARP — and **macOS ignores
it through vmnet**, converging only when its own ARP cache revalidates. talos-box's own
spec says so: "the slow-L2 failover caveat is macOS/vmnet-specific" (upstream
`docs/SPEC.md` §5).

**How you would notice.** Stop a node (module 05's fault work, or a `tbx` node restart)
and every `*.cloudbox.k8s.test` URL hangs for the better part of a minute before the
surviving node answers. Nothing logs an error; it just sits there.

This is **not a bug in the workshop and not a bug in Cilium**, and it is emphatically not
something to "fix" with BGP eight days before the event. If a demo needs a deterministic
failover story, do it on the docker substrate, where there is no VIP to move.

**Retired by:** nothing in 2026. It is an Apple networking behaviour; the honest move is
to say the number out loud when it happens.

## TRAP — a full-tunnel VPN blackholes 172.30.0.0/16, and detection-time `tbx doctor` is green anyway

A full-tunnel VPN/ZTNA client that claims `172.16.0.0/12` installs a route more specific
than the one vmnet put there, and every host→cluster packet leaves through `utun*` and
dies in somebody's datacenter.

`tbx doctor` **does** check for this — but only once a cluster is *running*. Its `routes`
check `route -n get`s each running cluster's gateway and first live node IP and fails if
the interface is neither a bridge/vmnet interface nor `lo0`, with the detail "a VPN/ZTNA
client has captured the cluster subnet" (`cmd/tbx/doctor_routes.go:35-84`,
`cmd/tbx/doctor.go:302-317`; remediation in upstream `docs/macos.md:84`: "Disconnect or
split-exclude the VPN/ZTNA client that captured `172.30.0.0/16`, then restart the
cluster"). The trap is *when* we ask:

- **Detection runs doctor before any cluster exists.** `substrate_detect()`
  (`substrate_detect_into()` / `substrate_detect()`, `scripts/lib.sh:247-259`) uses `tbx doctor`'s exit code to choose the substrate, and at
  that moment `routes` is a `SKIP` — "no clusters exist" (`cmd/tbx/doctor.go:270-277`), as
  it also is for a cluster that exists but is stopped (`:293-300`). So a VPN'd laptop
  passes detection cleanly and gets sent down the tbx path.
- **`routes` covers the gateway and node IPs, not the ingress VIP.** The workshop's
  hostnames all resolve to `172.30.<n>.200`, which is in the same subnet — so in practice
  a capture takes both — but a green `routes` is evidence about the nodes, not a promise
  about the VIP.

**How you would notice.** The cluster is genuinely healthy — nodes Ready, `tbx status`
green — and every `*.cloudbox.k8s.test` URL times out. It reads like a broken ingress. It
is a routing table.

**First move: re-run `tbx doctor` now that the cluster is up.** It will FAIL on `routes`
and name the fix. Confirm by hand with `route -n get 172.30.0.200` (macOS) naming a
`utun*` interface instead of a bridge. Do not go looking in Cilium.

**Fix:** disconnect the VPN, or split-exclude `172.30.0.0/16`, then restart the cluster —
or run the fallback, `CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh`, which needs
no host route at all.

**Retired by:** upstream teaching detection-time doctor to check the *configured* subnet
before a cluster exists. Until then, `tbx doctor` after `create-cluster.sh` is the check
that matters, and it is worth saying so from the front of the room.

## TRAP — /etc/hosts needs sudo, and it is the only sudo in the workshop

The docker substrate has no resolver of its own, so the same hostname scheme both
substrates serve has to come from somewhere: `create-cluster.sh` calls
`write_hosts_block` (`scripts/lib.sh`), which replaces a block marked
`# cloudbox-begin` / `# cloudbox-end` in `/etc/hosts` via a temp file and `sudo tee` —
never an in-place `sudo sed`, because a half-written `/etc/hosts` breaks name resolution
for the whole machine. Twelve names go in: the nine services plus `hello-demo.kn`,
`uploader-pipeline.kn` and `resizer-pipeline.kn`, because `/etc/hosts` has no wildcards
(the dash is Knative's `domain-template` — see the retired Knative-namespaces entry below).
The tbx substrate writes nothing — talos-box's resolver answers `*.cloudbox.k8s.test` —
so this prompt appears on exactly half the room's laptops.

**How you would notice** if the attendee declines the password (or has no sudo at all):
every hostname fails while the cluster is perfectly healthy, which is the same symptom as
the VPN trap above and reads like a broken ingress. A declined `sudo tee` is handled rather
than left to `set -e`: `write_hosts_block` deletes its temp copy of `/etc/hosts` (it would
otherwise sit in `$TMPDIR` forever).

**Where the prompt sits, and why that is load-bearing.** It is the LAST thing
`create-cluster.sh` does — after `substrate_post_ready`, with the cluster proven healthy.
It used to run between the Cilium install and the Ready wait, and `write_hosts_block`
*died* on refusal: a declined password threw away a half-built cluster, and the one
recovery an attendee would try — re-running `create-cluster.sh` — is refused by preflight,
because the node containers that very run created are exactly what preflight looks for. There
was no re-entrant writer at all (`--add-hosts` needs a name to add). So the writer now
warns and returns non-zero, the create finishes and says so, and
**`./scripts/install.sh --write-hosts`** is the zero-argument, idempotent command —
available on the **docker and kind identities** (the lifeboat maps host port 80 to the
ingress NodePort and needs the very same block; refusing there would leave the machine
that needs the repair most with no command for it) and refused on tbx — that writes the
block whenever the attendee is ready. `--add-hosts <name>` accepts the same two.
Both additionally require that the identity they resolve to is the one
`~/.cloudbox/substrate` *records*: `CLOUDBOX_SUBSTRATE=docker ./scripts/install.sh
--write-hosts` on a tbx machine used to write exactly the block the tbx preflight dies
on.

**WSL2 deletes the block on every restart.** `generateHosts` defaults to true, so WSL
regenerates `/etc/hosts` from the Windows hosts file at boot and the block written
yesterday is gone this morning — with the containers still running, which makes it look
like an ingress that broke overnight. `lab/00-setup` and the README give both fixes:
`[network]\ngenerateHosts = false` in `/etc/wsl.conf`, or `--write-hosts` after each
restart. `install.sh --check` detects it (WSL2 + a "This file was automatically generated"
header + no block) and prints both.

**What handles it.** `install.sh --check` names the missing lines and how many;
`./scripts/install.sh --print-hosts` prints the block for hand-application, and on WSL2
also prints the note that the same lines belong in
`C:\Windows\System32\drivers\etc\hosts`, edited as Administrator, for the Windows browser
to resolve them. **Every** `destroy-cluster.sh` on the docker
substrate *asks to* remove the block again — not only `--purge-mirror`, which is how it
used to be:
a block left behind after a docker destroy points nine names at `127.0.0.1`, and
`/etc/hosts` beats talos-box's resolver, so the *next* cluster created on tbx has every URL
silently dead on a perfectly healthy cluster. `substrate_preflight` on the tbx backend now
refuses to create over leftover entries for the same reason. "Asks to" is exact: the sudo
prompt is the one step of a teardown an attendee can decline, so `remove_hosts_block` is
never fatal — it returns 1, the destroy still purges the mirror and prints its summary,
and the summary names the lines that are still there. Dying at that prompt used to skip
everything after it, including the 7 GB mirror the attendee had just asked to purge.

**"Leftover" also means a name on somebody else's line.** `/etc/hosts` lets one address
carry any number of names, so `127.0.0.1 localhost gitea.cloudbox.k8s.test` resolves gitea
exactly as its own line would — and the first version of this sweep matched the name only
in the FIRST position after the address, so that line was invisible to every caller: the
tbx staleness check called the file clean, `--check` reported the name missing while the
machine resolved it, and the destroy left it behind. `hosts_loopback_scan` in `lib.sh`
parses fields (comments stripped, address field must be `127.0.0.1`, any later field may
be one of ours) and is the single definition all three questions are asked through.

**"Leftover" means the ENTRIES, not the markers.** The tbx preflight and `--check` used to
ask "is the begin marker there?", which is the narrowest possible version of the question:
a `127.0.0.1 gitea.cloudbox.k8s.test` line whose marker comments someone deleted by hand
breaks tbx exactly as hard, and passed. `hosts_block_stale_for_tbx` is true for any marker
*or* any CloudBox name (pins **and** the attendee's `--add-hosts` extras) pointing at
`127.0.0.1`, and both callers print the offending lines with their line numbers, because
"remove the CloudBox lines" is advice only someone who already knows which lines those are
can follow. `remove_hosts_block` prints the same list when it refuses an unpaired file.

**And "correct" means the whole block.** `hosts_block_present` compares the marked block
against what `cloudbox_hosts_block` would write today, rather than checking that every
current name is listed. The old rule could only detect names that were *missing*: a name
removed from `~/.cloudbox/extra-hosts` — the documented way to stop resolving one — left
its `127.0.0.1` line in `/etc/hosts` forever and still reported "already correct".

Both rewrites also refuse to run at all unless the markers form exactly one ordered pair
(`assert_hosts_block_wellformed`). The awk they use skips from the begin marker to the end
marker, so a file with a begin marker and no end marker — a half-finished hand edit, an
interrupted `sudo tee` — would have had **every line after it deleted**, including the
machine's own `localhost` and whatever an employer's MDM put there.

**Retired by:** nothing — it is the price of one hostname scheme on a substrate with no
resolver. Say it out loud before `create-cluster.sh` runs so nobody is surprised by a
password prompt from a workshop script.

## TRAP — `.200` resolves before anything owns it

talos-box's resolver answers `*.<domain>` with the cluster's `172.30.<n>.200` for the
cluster's whole lifetime — "tied to the cluster's existence, not its run-state" (upstream
`docs/SPEC.md` §5). The address is a convention, not a claim: nothing owns it until
Cilium's `cilium-ingress` Service is allocated it out of the `.200-.239` pool.

**How you would notice.** Between `tbx up` and the ingress getting its VIP — and on any
cluster that is up but has no Cilium yet — every hostname resolves instantly and every
connection is refused. A name that resolves reads as "the service is there and broken",
when the truth is that it does not exist yet.

**Why the scripts are shaped the way they are.** `substrate_post_ready()`
(`substrate_post_ready()`, `scripts/substrate/tbx.sh:550-584`) waits up to 180 s for `cilium-ingress` to actually
carry a LoadBalancer address, and fails loudly there rather than letting module 02 discover
it; it also **dies** if the VIP is not `.200` — the resolver answers `.200` unconditionally,
without consulting who holds it, so an ingress anywhere else in the pool means every
hostname in the workshop points at nothing while the cluster looks perfect. That used to
be a warning, i.e. an attendee was handed the broken cluster anyway. `lab/01-cluster/verify.sh`
asserts the same thing on the tbx branch. Fix it by deleting whichever other LoadBalancer
Service took `.200` first (`kubectl get svc -A --field-selector spec.type=LoadBalancer`)
and re-creating; do not repoint the resolver.

## TRAP — the pinned portal image predates `KNATIVE_DOMAIN`

The Console builds the URL of every function it lists from a domain it now reads
out of the environment: `KNATIVE_DOMAIN`, defaulted in `apps/portal/config.go:54`
and used by `ksvcURL` (`apps/portal/internal/web/applications.go:95-97`).
`gitops/components/portal/portal.yaml:116-117` is the env entry that sets it. That code landed on the
substrate branch; **the image it runs does not have it yet.**

`ghcr.io/randax/cloudbox-portal:v0.2.2` — pinned in exactly two places,
`scripts/images.txt:169` and `gitops/components/portal/portal.yaml:83` — was
built before that commit, and its binary hardcodes `127.0.0.1.sslip.io:31080`.
So until the next release is published, module 08's Console shows function URLs
that are wrong **on both substrates**: they are not the `<name>-<namespace>.kn.cloudbox.k8s.test`
names Knative actually programs (`gitops/components/knative-serving/serving-core.yaml`'s
`domain-template`, routed by the single wildcard rule in `ingress.yaml`),
and `127.0.0.1.sslip.io:31080` reaches nothing on tbx at all.

**Do not fix this by editing the tag.** Pins are not hand-edited in this repo:
`release-please` rewrites all of them from `extra-files` in the release PR
(`release-please-config.json`, `.github/workflows/build-images.yaml:20-21`). A
hand-bumped tag points at an image that does not exist yet — which is the
publish-window trap below.

**Why the release will be cut.** `release-please` in manifest mode assigns
commits to the `apps` package by the **files they touch**, not by the
conventional-commit scope: the branch's `feat(labs): sweep every browser-facing
URL…` (`e9585df`) touches `apps/portal/*.go`, as do `ee8837e` and `a6f03fd`. Two
`feat`s under `apps/` means the release PR bumps `0.2.2` → `0.3.0` and
`build-images` publishes `cloudbox-portal:v0.3.0`.

**Retired by, in order:** merge to `main` → `release-please` opens the release PR
(pins rewritten in it) → merge that → `build-images` publishes the images →
verify every ref resolves (the `crane manifest` loop in the publish-window entry
below) → `./scripts/cloudbox-init.sh` re-mirrors. **Step 0 of rehearsal 5**
(`docs/REHEARSALS.md`) — nothing else in that rehearsal proves the Console's
function URLs until it is done.

## RESOLVED — tbx's catch-all registry mirror would have broken every image we build

Found by adversarial review before any rehearsal ran it, which is the only reason it is in
this section and not in a post-mortem.

`substrate_create()` on the tbx backend used to append `tbx manifests <cluster> mirrors` to
the machine config as a bonus layer, on the reasoning that "explicit entries win over `*`
in containerd, so this only covers registries our list does not name" — which is true, and
was the wrong thing to conclude from. What that patch renders (upstream
`internal/manifests/manifests.go:218-231`) is a `RegistryMirrorConfig` for `"*"` with
**`skipFallback: true`**, and the registries our list does not name include
**`localhost:30500`** — the in-cluster Zot, which is how the kubelet pulls every image
lab 07, lab 09 and the Console *build*. tbx's mirror refuses to proxy a loopback or private
authority (403 out of `validateResolvedAuthority` → `namespaceIPBlocked`,
`internal/mirror/manager.go:313-327` and `:667-680`), and `skipFallback: true` forbids the
direct pull that would otherwise rescue it. Every first-party image would have landed in
`ImagePullBackOff`, on the tbx substrate only, from module 07 onward.

**Why it looked safe.** Both halves of the reasoning were individually correct — explicit
entries *do* win, and taking a free pull-through cache *does* normally cost nothing. The
step that was missing is that `"*"` is not "the registries you forgot", it is *every*
registry, including the one that is a lie about locality.

**Fixed by** dropping the patch entirely. Our eight explicit mirrors cover everything in
`scripts/images.txt`; the catch-all bought nothing that list did not already have.
`check-consistency.sh` check 11 is unaffected — it compares the `cni:none` patch, which is
still byte-identical across the two backends.

**Superseded** — see the next entry: the conclusion "drop tbx's mirror" was one step too
far. The hazard is the `"*"` *entry*, not the *port*.

## RESOLVED — the tbx nodes pull through tbx's own mirror; the crane-container hop was the stall

The entry above ended with "dropped tbx's mirror", and the tbx substrate went on pulling
from the crane container on `localhost:5001` — reached from a VM as Talos VM → vmnet →
macOS → Colima VM → container. **Rehearsal 6 (2026-08-28) is what that cost**: 60 MiB
blobs froze in that chain, `kubelet` and `etcd` sat in `Preparing` with a byte count
that never moved, both nodes stayed `NotReady`, and one node needed a manual reboot
before the cluster came up (`docs/REHEARSALS.md`, rehearsal 6). Meanwhile tbxd was
serving a pull-through mirror at `172.30.<n>.1:5059` — *on the gateway address
itself*, no hop — and nothing used it.

**The distinction the previous entry missed.** What breaks `localhost:30500` is
containerd applying a **`"*"` mirror entry** with `skipFallback: true` to every registry
the config does not name. An **explicit** entry (`ghcr.io:` → `http://172.30.<n>.1:5059`)
applies to `ghcr.io` and nothing else; containerd sends `?ns=ghcr.io` on each request and
tbx's catch-all *port* routes on that namespace (`internal/mirror/manager.go`,
`serveCatchAll`). The port is safe to point explicit entries at; the `"*"` entry is what
must never be rendered. Both halves of the earlier reasoning were right and the
conclusion drawn from them was wrong — for the second time on this one topic.

**Fixed by** issue #206: `scripts/substrate/tbx.sh` keeps the eight explicit registries
and `skipFallback: false`, with the endpoint `http://${CLOUDBOX_HOST_GATEWAY}:${TBX_MIRROR_PORT}`
(`versions.env`, the one place `5059` is written). `/v2/` is curl-proved at the gateway
before it is baked into the machine config. `cloudbox-init.sh` warms that store with
`tbx cache warm` over a generated `[mirror]`-only list (`images_mirror_refs`, `lib.sh` —
`images.txt` as-is fails tbx's ref validation on its section headers), `install.sh
--check` grades it with `tbx cache warm --check` (`--deep` rehashes), and **the tbx path
needs no Docker at all**: the `[host]` images, the crane container and the Docker gates
in `tbx.sh`, `install.sh` and lab 00's `verify.sh` are docker/kind-only now. `tbx mirror
offline on` is the venue switch. talos-box separately fixes the `"*"` footgun in its
rendered manifests (randax/talos-box#481), but this repo never renders that entry
regardless.

**What it costs:** tbx's store serves VMs only. A tbx laptop whose prework ran only the tbx
warm has **no offline docker/kind fallback** — `CLOUDBOX_SUBSTRATE=docker
./scripts/create-cluster.sh` and `kind-fallback.sh` would pull the Talos node image, the
kind node image and 7.5 GB of cluster images over the venue WiFi. `cloudbox-init.sh` says
so at the end of the tbx warm, and the remedy (run it again with
`CLOUDBOX_SUBSTRATE=docker`, at home, with Docker) is printed there; the fallback is a
pre-venue remedy on tbx, not a venue one. Decided in #206 rather than paying twice the
prework for everyone.

**What is NOT retired:** as of 2026-08-28 the mirror-through-tbx path is **unrehearsed**
— it was decided and built after rehearsal 6, and proving it end to end (create, the
eleven modules, and offline with `tbx mirror offline on`) is rehearsal 7's job. And the
`k8sClientRateLimit`/`bpf.hostLegacyRouting` VIP-blackout question (issue #209) is a
separate open thread, not a mirror one.

## RESOLVED — a Knative Service in a namespace nobody listed had no route at all

`gitops/components/knative-serving/ingress.yaml` used to carry one wildcard rule **per
namespace** — `*.demo.kn.cloudbox.k8s.test` and `*.pipeline.kn.cloudbox.k8s.test` — with a
comment explaining, correctly, that a Kubernetes Ingress wildcard host matches exactly one
DNS label and Knative's default hosts are two labels deep (`<name>.<namespace>.<domain>`).

The gap is what the comment then said: "a ksvc in a THIRD namespace needs another rule
here." Modules 08 and 09 create ksvcs in namespaces **chosen by the attendee** — the
Console's Application XR composes into whichever project they picked — so "add another
rule" is advice nobody can act on at the time it is needed, and the symptom is a Ready
Knative Service, a published `.status.url`, and a 404 from the ingress.

**Fixed by** curating Knative's `domain-template` to
`"{{.Name}}-{{.Namespace}}.{{.Domain}}"` (upstream's own documented alternative for exactly
this problem, quoted in the `_example` block of `config-network`). Every ksvc host is then
**one** label under `kn.cloudbox.k8s.test`, and one `*.kn.cloudbox.k8s.test` rule serves
every namespace that will ever exist. `.status.url` reports the dashed host, so the labs'
verifiers — which read it rather than assuming a shape — needed no change.

**What is still substrate-shaped**, and is documented rather than fixed: on **docker**
`/etc/hosts` has no wildcards, so only the three ksvc names the labs create are listed
(`hello-demo`, `uploader-pipeline`, `resizer-pipeline`). An attendee who invents their own
app on the docker substrate still needs a manual hosts line, `curl -H "Host: …"`, or
NodePort 31080 — lab 06 says so. On **tbx** the resolver answers the wildcard and anything
they create just works.

## TRAP — the dash that made routing work put the name and the namespace in one DNS label

`domain-template: "{{.Name}}-{{.Namespace}}.{{.Domain}}"` is what lets a single
`*.kn.cloudbox.k8s.test` wildcard Ingress serve every namespace (see the
RESOLVED entry above). The price is that a ksvc's name and its namespace now
share **one DNS label**, and a label has two properties nothing else in
Kubernetes imposes on this pair:

**1. 63 characters, together.** `metadata.name` may be 253; a hostname label may
be 63. A 40-character name (the Console's own cap) in a 30-character project
namespace composes a 71-character host. Knative builds it anyway and publishes
it in `.status.url`, so the failure is an Application whose XR, ksvc, revision
and pods are **all Ready** and whose URL has never worked — the exact shape
nobody debugs by counting characters.

*What handles it:* `ValidKnativeHost` in
`apps/portal/internal/kube/resources.go` refuses `len(name)+1+len(ns) > 63` at
both doors (`BuildApplication`, and `BuildFunctionService`, whose ksvc is
`fn-<name>` — those three characters come out of the same budget), with the
shortfall in the message. Covered by `TestKnativeHostLabelLength`. The
`Application` XRD caps `metadata.name` at 40 so `kubectl apply` and the Console
agree; a schema cannot check the pair, because it does not know the namespace.

*And a CEL rule cannot close that gap* — two independent reasons, both read in
the sources rather than inferred, so the next person does not spend an afternoon
on `size(self.metadata.name) + 1 + size(self.metadata.namespace) <= 63`:

1. **Kubernetes does not expose the namespace to CEL.** Validation rules can
   select `apiVersion`, `kind`, `metadata.name` and `metadata.generateName`, and
   the CRD documentation is explicit that "No other metadata properties are
   accessible". `self.metadata.namespace` does not exist for a rule.
2. **Crossplane would drop a root-level rule anyway.** `genCrdVersion`
   (`internal/xcrd/crd.go`, v2.0.0) builds the CRD schema from `BaseProps()` and
   copies `XValidations` from the XRD's `spec` and `status` sub-schemas only
   (`cSpec.XValidations`, `cStatus.XValidations`); from the root it takes the
   description and `metadata.properties.name.maxLength`, nothing else.

So the 40-character cap really is the floor, the Console really is the only
place the pair is checked, and a hand-written XR in a long namespace is a
documented limitation — lab 04 says so in the attendee's own words.

**2. The dash is ambiguous.** `a-b` in namespace `c` and `a` in namespace `b-c`
both compose `a-b-c.kn.cloudbox.k8s.test`. Whichever Knative programmed last
owns the host; the other silently answers the wrong app. Nothing detects this —
not Knative, not Cilium, not the Console.

*What handles it:* the workshop's namespaces (`demo`, `pipeline`) have no
hyphens, which makes the split unambiguous by construction. The rule to keep is
**project namespaces without hyphens**; with a hyphen-free namespace the last
dash-group is always the namespace, and no two (name, namespace) pairs can
collide. A `my-project` namespace is the first thing that would break it.

That rule used to live only in this file, while lab 08 told attendees to create
a project called `team-a` — the exact shape it forbids. It is now enforced where
project namespaces are created: `kube.CreateProject`
(`apps/portal/internal/kube/projects.go`) refuses a name containing `-` and says
why, the New-project form's pattern and placeholder match
(`[a-z0-9]+`, `teama`), and `TestCreateProjectRejectsHyphen` covers both doors.
Deleting a hyphenated project still works — the rule is on the way in.

Creation was, for one round, the *only* door that asked. A namespace made by
hand (or before the rule) with the project label was listed by the selector,
could be switched into with `?set=team-a`, and every mutating route trusted the
`project` cookie after a mere `ValidName` check — so the console would happily
deploy into it and re-open the collision above. The rule is now one predicate,
`kube.ValidProjectName`, asked at creation, at `/project?set=`, when the cookie
is consumed (`activeProject`) and again at every mutating route
(`mutableProject`, which refuses rather than silently redirecting the write into
`demo`). A legacy hyphenated project stays **listed and deletable, and is
read-only**: no switch, no create, no deploy.
`TestLegacyHyphenatedProjectIsReadOnly` covers the three doors. CI fixtures are
held to the same rule by check 13 in `check-consistency.sh` — a hyphenated
`proj=` in the e2e workflow is a red run 40 minutes in, which is how `team-e2e`
got there in the first place. The
`Application` composition creates no namespace of its own (it composes into the
XR's), so a hand-created namespace is the only remaining way in; lab 04 and lab
08 state the rule for that case.

**Retired by:** nothing. The alternative is the dotted default template, which
costs every namespace its own Ingress rule — that is the bug the dash fixed.
Both properties are inherent to putting two names in one label.

## LIVE — Ollama binds to loopback, and on tbx the cluster is not on loopback

kagent's ModelConfig points at `<host-gateway>:11434`, written by
`bootstrap-gitops.sh` from `cloudbox_host_gateway()`. The gateway differs by
substrate, and so does whether Ollama's default bind can serve it:

- **docker/macOS** → `host.docker.internal`, which Docker Desktop maps onto the
  host's loopback. A `127.0.0.1:11434` Ollama answers. This has worked for four
  rehearsals, which is why nobody has hit it.
- **tbx** → `172.30.<n>.1`, a real vmnet address on the host. Ollama's default
  bind is `127.0.0.1:11434`, so that connection is **refused**.

**How you would notice.** Module 10's agent never answers. kagent is up, the
ModelConfig holds the right host, the model is pulled — and every inference call
fails at connect. It reads like a broken agent; it is a bind address.

**What handles it.** `cloudbox-init.sh` probes this during prework, on tbx only:
it confirms Ollama answers on `127.0.0.1:11434`, then reads the LISTEN address
(`lsof -nP -iTCP:11434 -sTCP:LISTEN` on macOS, `ss -ltn` on Linux) and **warns**
— never dies, the model is optional and this runs inside the image pre-pull
everyone needs — naming the fix:

    launchctl setenv OLLAMA_HOST 0.0.0.0    # macOS, then quit and reopen Ollama.app
    OLLAMA_HOST=0.0.0.0 ollama serve        # if you run it in a terminal

`lab/00-setup/README.md` says the same in the tbx prerequisites.

**Retired by:** a rehearsal-5 module 10 on tbx that reaches the model (step 9).
Nothing about this is provable on the docker substrate.

## LIVE — host port 80 is the only privileged port the workshop binds

On docker, `substrate/docker.sh` publishes `80:${NODEPORT_INGRESS}` from the
controlplane container. That single entry is what makes
`http://<name>.cloudbox.k8s.test` work without a port, the way the LoadBalancer
VIP does on tbx — and it is the one port the workshop cannot pick differently.

Everything that collides with it is ordinary: a local dev web server, another
kind/Talos cluster, a system Apache/nginx, and on Colima/Lima the VM's own
privileged-port forwarding (which needs to be enabled and can fail on its own
terms). `install.sh --check` tests port 80, but **only before a cluster exists** —
a listener started between the preflight and the create is invisible to it.

**How you would notice.** `talosctl cluster create` dies with a docker port
binding error that names the port and not the owner.

**What handles it.** The create call is wrapped: on failure it says port 80 is
the likely culprit and prints who holds it (`lsof -nP -iTCP:80 -sTCP:LISTEN`, or
`ss -ltn`), and points at the substrate that needs no host port at all —
`CLOUDBOX_SUBSTRATE=tbx ./scripts/create-cluster.sh`. On macOS the holder can be
inside the Docker/Colima VM, where the host's `lsof` cannot see it; the message
says to check `docker ps --filter publish=80` too.

**Retired by:** nothing — a port-free hostname scheme on a substrate with no
LoadBalancer costs exactly one privileged port. Rehearsal 5 step 13 runs the
docker path on the same Mac and, if Colima is available, under Colima.

## RESOLVED — NodePorts had no proxy in the path; hostnames have Envoy, and Envoy times out at 15 s

The substrate split moved every browser-facing URL from a NodePort to a
hostname served by Cilium's ingress. A NodePort is kube-proxy/eBPF: no L7 proxy,
no request timeout, a `git push` can take a minute. A Cilium Ingress is an
**Envoy** route — and Envoy's default route timeout is **15 seconds**.

Cilium does not set the route timeout unless something asks for one:
`operator/pkg/model/translation/envoy_virtual_host.go:495-503` sets only
`MaxStreamDuration: 0` when neither a backend nor a request timeout is
configured, leaving `route.Timeout` unset — i.e. Envoy's default. Nothing in the
chart's values sets one either (grep `cilium-1.20.0.tgz` for
`request-timeout`: the only `ingress-default-*` keys in `cilium-configmap.yaml`
are lb-mode, xff hops and the default secret).

**What would have broken, at 15 s exactly:** `seed-gitea.sh`'s ~40 MiB push over
`gitea.cloudbox.k8s.test`, every attendee push after it, the Console's SSE
`agent-ask` stream (module 10 answers routinely run longer), ArgoCD's gRPC-web
watches, and a scale-from-zero ksvc's first request. All as a **504 from a
healthy platform** — the failure shape nothing in the room diagnoses.

**What handles it.** Two layers:

1. `create-cluster.sh` passes
   `--set "operator.extraArgs[0]=--ingress-default-request-timeout=24h"` to the
   Cilium chart — the global default for every Ingress, including ones
   attendees create. Verified to render:
   `helm template … | grep ingress-default-request-timeout`.
2. The four long-lived ingresses (gitea, argocd, portal, kourier) carry
   `ingress.cilium.io/request-timeout: "0s"`.

**The trap inside the fix — do not "simplify" the 24h to 0.** The flag's own
default is `0` and the ingestion code skips it exactly when it is zero:
`operator/pkg/model/ingestion/ingress.go:46` is `if defaultRequestTimeout != 0`.
Setting `0` on the operator is a **no-op that reads like a fix**. The flag cannot
express "no timeout" at all; only a duration long enough to never be reached.
The *annotation* is different: `:49-58` takes any parsable value including `0s`
into a non-nil pointer, and Envoy reads route timeout 0 as disabled — which is
why the per-Ingress form is the exact one and the global form is a big number.

**Retired by:** nothing; it is a permanent property of putting an L7 proxy in
front of everything. Re-check both citations on any Cilium bump — the flag name
(`--ingress-default-request-timeout`) and the annotation
(`ingress.cilium.io/request-timeout`) are both operator surfaces, and the
zero-is-unset semantics are the kind of thing that changes quietly.

## WATCH — `bootstrap-gitops.sh` creates namespace `kagent` before ArgoCD owns it

`bootstrap-gitops.sh:227` creates the `kagent` namespace imperatively
(`kubectl create namespace … --dry-run=client | kubectl apply -f -`) so it has
somewhere to put the `cloudbox-host` ConfigMap that records the substrate's
gateway. Module 10 then enables kagent, whose Application declares
`CreateNamespace=true` **and** ships `gitops/components/kagent/namespace.yaml`.

So ArgoCD meets a namespace that already exists, created client-side, and has to
adopt it. **This is expected to hold** — the imperative create sets no labels and
the manifest only adds `app.kubernetes.io/name: kagent`, so there is no field
whose ownership is contested — but it has never been run.

**Checked, not assumed:** the two definitions do not disagree. The manifest sets
no PodSecurity labels (kagent needs nothing beyond Talos's `baseline` default),
and the imperative create sets none either.

**How you would notice.** The `kagent` Application sits `OutOfSync` on the
Namespace resource after the first sync, or the sync reports a server-side-apply
field-manager conflict on `metadata`.

**Retired by:** rehearsal 5 step 9 — enable kagent and confirm the Application
reaches Synced+Healthy with the Namespace among its resources.

## WATCH — three settings have to agree for the Ollama host to survive selfHeal

The Ollama host is a MACHINE fact, so git carries a default that is right for
exactly one of the three cases (docker/macOS, docker/Linux, tbx) and the real
value is written at runtime. Three separate mechanisms keep it there, and all
three have to hold at once:

1. `ignoreDifferences` on `ModelConfig/default-model-config`,
   `/spec/ollama/host` (`gitops/catalog/kagent.yaml`) — so the diff is ignored;
2. `RespectIgnoreDifferences=true` — without it a **selfHeal** sync ignores
   `ignoreDifferences` and puts the git value back on every reconcile;
3. `ServerSideApply=true` — which means the patch's field manager matters:
   `bootstrap-gitops.sh:233` and the PostSync hook both use
   `kubectl patch --type merge`, whose manager (`kubectl-patch`) is not
   ArgoCD's, so `/spec/ollama/host` ends up owned by a manager ArgoCD does not
   speak for.

Expected to hold — `ignoreDifferences` is evaluated on the diff, before any
apply, so ArgoCD should never send that field. Unproven: nobody has watched an
SSA sync of this app after the patch landed.

**How you would notice.** Module 10's agent works once, then stops after ArgoCD's
next reconcile, with `.spec.ollama.host` back to `host.docker.internal:11434`.

**Retired by:** rehearsal 5 step 9 — `argocd app sync kagent`, then re-read
`kubectl -n kagent get modelconfig default-model-config -o jsonpath='{.spec.ollama.host}'`
and confirm it still names the substrate's gateway.

## RESOLVED — node containers were capped at 2.0 CPUs, whatever the laptop had

**Fixed in `33c84f7`; proven decisively in rehearsal 2.** Kept in full, because the
before/after *is* the evidence and because the residual at the bottom is live.

`talosctl cluster create docker` defaults **`--cpus-controlplanes` and
`--cpus-workers` to `2.0`** (its own `--help` says so), and
`scripts/create-cluster.sh` passed neither — it raised `--memory-controlplanes` /
`--memory-workers` deliberately and said nothing about CPU. So the entire
Kubernetes cluster ran inside a **4-CPU budget** no matter how many cores the
machine had:

    docker inspect cloudbox-worker-1 --format '{{.HostConfig.NanoCpus}}'
    2000000000                                     # = 2.0 CPUs

It was even in `talosctl`'s own creation summary (`CPU 2.00` per node), where
nobody reads it as a limit.

**What it did.** Everything schedules onto the one untainted worker. Modules
00–09 each passed on an 8-core machine without a hiccup, but at module 10's
canonical end state — 18 wave apps plus kagent, NATS and Backstage, 21 apps and
~125 containers — the worker ran out of CPU and the cluster came apart: kubelet
`HEALTH Fail` (`/healthz: context deadline exceeded`), `cloudbox-worker-1
NotReady`, then `kubectl` itself failing with `TLS handshake timeout` for tens of
minutes. The decisive reading, from inside the Colima VM:

    /proc/pressure/cpu:     some avg10=98.72 avg60=97.89 avg300=96.02
    /proc/pressure/io:      some avg10=2.56
    /proc/pressure/memory:  some avg10=0.00        full avg10=0.00

**98.7 % of the time some task is stalled waiting for CPU while the VM is only
~23 % busy and memory pressure is exactly zero** (worker 4.5/6 GiB, CP 3.2/4 GiB,
9.4 GB free). High CPU pressure + low absolute utilisation + no memory pressure
is cgroup throttling, not a machine that is too small.

**You could not rescue it afterwards.** `docker update --cpus 3` /
`--cpus 4` on the live containers dropped pressure 98.7 → ~92 but the cluster did
**not** come back within the next ~10 minutes; once kubelet is behind on ~125
containers the backlog outlives the fix, and draining it took ~20–30 minutes. The
caps have to be right *before* the load arrives — which is why this had to be fixed
in `create-cluster.sh` and not documented as a workaround.

**The fix is to cap nothing at all.** `create-cluster.sh` now reads the Docker
daemon's core count (`docker info -f '{{.NCPU}}'`), floors it at talosctl's own
`2.0` (`TALOS_CPU_FLOOR` in `versions.env`, so a minimum-spec machine is never worse
off than before) and passes it to **both** containers. That is deliberately
oversubscribed: a `--cpus` value equal to the host count is not a meaningful quota,
which is the point. Same rule we apply to our own workloads — requests schedule, a
CPU limit throttles rather than queues.

**Rehearsal 2, cold cluster, same laptop, same module 10 end state:**

    $ docker inspect cloudbox-{controlplane,worker}-1 --format '{{.HostConfig.NanoCpus}}'
    8000000000        # 8.0 CPUs each, was 2000000000 — and CpuQuota=0 CpuPeriod=0

| at module 10's end state | rehearsal 1 (2.0 CPUs/node) | rehearsal 2 (8.0 CPUs/node) |
|---|---|---|
| `/proc/pressure/cpu some avg10` | **98.72** (avg300 96.02) | **1.08** (avg300 2.97) |
| memory pressure | 0.00 | 0.00 (avg300 0.24), 7.7 GB available |
| worker node | `NotReady`, kubelet `HEALTH Fail` | `Ready`, kubelet `HEALTH OK` |
| `kubectl` | `TLS handshake timeout` for tens of minutes | instant |
| Kourier gateway | `ContainerCreating` ~11 min | 1/1 in seconds, 0 restarts |
| Backstage to Ready | **9 min 03 s** | **0 min 57 s** |
| apps / pods | wedged before reaching 21 | **21/21 Synced+Healthy, 73 pods** |

**~90× less CPU pressure, and no wedge** — and everything downstream got better at
the same time, which is the signature of one real bottleneck rather than a pile of
separate problems. Backstage's nine minutes was never the amd64 emulation; it was
the cap. Note also that rehearsal 1's hand-repaired cluster (3 CP / 4 worker, set
with `docker update` after the wedge) idled at `some avg10=1.30` with the same 21
apps, against the uncapped run's 1.08 under load: what mattered was removing the
quota, not the exact number.

**The residual, recorded honestly: we removed a throttle and put no bound in its
place.** Each node still advertises the **whole VM** to the scheduler, because
kubelet inside a Talos-in-Docker node reads the host's `/proc`, not its cgroup:

    $ kubectl get nodes -o custom-columns='NAME:…,CPU:.status.capacity.cpu,MEM:.status.capacity.memory'
    cloudbox-controlplane-1   8   16340372Ki
    cloudbox-worker-1         8   16340372Ki
    # → the scheduler believes it has 16 CPU / 32 GiB, on an 8 CPU / 16 GiB VM

Nothing stops a genuinely oversubscribed cluster. Option (3) from the original
entry — give the observability stack real resource requests, so the scheduler
refuses instead of thrashing — is still unimplemented and is still the right belt to
go with these braces. On 8 cores it does not bite; the next entry is where it might.

## LIVE — `MIN_CPUS="4"` is now under-specified rather than wrong

All four rehearsals ran on the same **8-CPU** host. `MIN_CPUS="4"` is a published
promise (principle 12, honest specs) and `install.sh --check` enforces it, but what has
actually been measured at the module 10 end state — 21 apps, 66–73 pods — is 8 cores,
four times, and nothing else.

Uncapping helps a 4-core laptop rather than hurting it: with `TALOS_CPU_FLOOR="2"`
and a 4-CPU daemon, both node containers now get **4/4 where they previously got
2/2** — strictly more than any attendee has ever had. But "better than before" is
not "measured", and the residual above means the scheduler on such a machine will
happily over-commit two nodes that each claim 4 CPUs.

One piece of evidence does exist and is worth naming precisely: `bootstrap-test.yaml`
runs on a **4 vCPU / 16 GB** `ubuntu-latest` runner and the repo's own header claims
the core path (01–07) green there. So what is untested at 4 cores is not the workshop —
it is specifically the **stretch end state**, modules 08–10, the 21 apps and 73 pods
that wedged an 8-core machine when it was throttled to 4.

**Unresolved — a maintainer decision, not a patch.** Options, in the order worth
considering: (1) keep `MIN_CPUS="4"` as the **core-path (00–05)** gate, which is
what `versions.env`'s comment now says it is, and state in modules 06–10's
prerequisites that the full stack wants ≥8 cores; (2) raise the minimum for the
stretch path and say so in the published matrix; (3) implement the resource
requests, the only option that makes a 4-core machine degrade instead of thrash;
(4) measure it — one `catch-up.sh 10` on a 4-CPU Docker daemon would settle the
whole question in twenty minutes.

**What `--check` actually enforces, precisely.** On the docker substrate it reads
`docker info -f '{{.NCPU}}'` — the daemon's slice, which since the uncapping fix
is also what the cluster gets. On tbx that number is meaningless (the nodes are
VMs; Docker only runs the mirror), and for one round the CPU gate was therefore
skipped on tbx **entirely**: a 2-core laptop passed a preflight whose README
promises 4. It now reads the host directly (`host_cpu_count()` in `lib.sh` —
`getconf _NPROCESSORS_ONLN`, the same expression that sizes the worker VM), on
the tbx branch of `install.sh --check` and in `lab/00-setup/verify.sh`. Neither
gate can tell a 4-core machine that modules 08–10 are untested on it; that is
still the open decision above.

## RESOLVED — the lifeboat needed the internet, and sank without it

**Found in the 2026-08-18 recovery pass, fixed in `a40852a`.** The single worst
finding of five rehearsals, because of *who* reaches it.

`scripts/kind-fallback.sh` is the documented Plan B: the thing a helper points
someone at when Talos-in-Docker will not run on their laptop. It ran
`helm repo add cilium https://helm.cilium.io` **at run time** — so on venue WiFi,
reached by someone whose cluster has already failed, it timed out and exited 1
**after creating the kind cluster**, leaving a CNI-less wreck whose
`kind-cloudbox` context the workshop's own context guard happily accepts.

`create-cluster.sh` has vendored that chart since day one, with a comment saying
*"so this needs no internet at the venue"*. The lifeboat simply never got the same
treatment — and **nothing had ever run it.** It is exercised by no CI job and no
rehearsal; four full end-to-end passes never touched it, because a lifeboat is
only reached when something else has already gone wrong.

Now uses the same vendored chart: **exit 0 in 49 s, both nodes Ready, offline.**

**The general lesson: the paths that only run when someone is already in trouble
are the least-tested code you ship, and the most expensive to get wrong.** Every
blocker in five rehearsals came from recovery or setup, never from the platform.

## RESOLVED — the lifeboat published nine ports and could not answer one name

The same lifeboat, one layer up. `kind-fallback.sh` held a **shape** contract:
1 CP + 1 worker, `disableDefaultCNI`, `kubeProxyMode: none`, the vendored Cilium
chart, the nine workshop NodePorts published on localhost. That was the whole
contract while the workshop's URLs *were* NodePorts.

The substrate split moved every URL to a hostname behind the shared Cilium
ingress — and the lifeboat installed Cilium **without the ingress controller at
all**, mapped no host port 80, and wrote no `/etc/hosts` block. So the first
thing an attendee does after taking the lifeboat is `./scripts/seed-gitea.sh`,
which pushes to `gitea.cloudbox.k8s.test`: a name nothing on that machine
resolves, to an ingress that was never installed. **Module 02, first command.**

Fixed by giving it the docker substrate's contract rather than a description of
it: `extraPortMappings` 80 → `NODEPORT_INGRESS`, `cilium_ingress_values`
(`scripts/lib.sh`) — the *same function* `create-cluster.sh` calls, asked for the
same `nodeport` shape — and `write_hosts_block` after Ready, non-fatal, exactly
as the create path does it. check-consistency 11b asserts both callers still
share that function and that neither grew a private `--set ingressController.*`.

The teardown is `./scripts/kind-fallback.sh --delete`, which deletes the cluster
**and** removes the hosts block — otherwise the block outlives the lifeboat and a
later tbx create dies on it (`hosts_block_stale_for_tbx`).

**Still true of this file: nothing has ever run it end to end.** No CI job, no
rehearsal. It is exercised only by someone already in trouble. Retired by a
rehearsal that takes the lifeboat deliberately and runs modules 02→05 on it.

## RESOLVED — "kind is not a substrate" made it invisible to everything

Round 8. kind is not a substrate, and the first fix drew the conclusion that it
should therefore write **nothing** into `~/.cloudbox/substrate`. That file is not
a substrate flag, though — it is the answer to *"what is this machine running?"*,
and leaving it empty on a lifeboat machine did not make the question go away. It
made every helper answer it wrong, in the same direction:

* `install.sh --check` graded a lifeboat as the docker substrate: it scanned the
  ten host ports the lifeboat had just published (ten manufactured FAIL lines on
  a healthy machine), or — with no cluster recorded — reported "no cluster yet".
* `destroy-cluster.sh` read *no answer* as **docker** (deliberately: that is the
  substrate whose leftovers can exist without a persisted answer), found no Talos
  containers, and went on to remove the `/etc/hosts` block and the kubeconfig
  entries **of a kind cluster that was still running**.
* `mirror_target_substrate` fell back to `have tbx`, so a lifeboat on a Mac with
  tbx installed filled its mirror for arm64 VMs it does not have.
* `cloudbox_host_gateway()` answered `${TALOS_SUBNET_GATEWAY}` on native Linux —
  the docker substrate's `cloudbox` network gateway, an address that does not
  exist on a machine whose nodes are on kind's own bridge.
* `bootstrap-gitops.sh` sent lifeboat attendees to `tbx status`.

So `kind` is now a **third persisted identity**: `kind-fallback.sh` writes it
right after the cluster is created (before Cilium, like `create-cluster.sh`
persists before its create — the failures that leave a wreck behind are the ones
that need the identity most) and `--delete` clears it.
`substrate_persist/current/resolve` accept it from the file or from an explicit
`CLOUDBOX_SUBSTRATE=kind`; **detection never returns it**, because nothing about
a machine says "this one should use the lifeboat"
(`substrate_detectable`, `scripts/substrate-decide.sh`). `create-cluster.sh` and
`destroy-cluster.sh` refuse on it by name, and the destroy refuses **before**
touching the hosts block. `--delete` removes that block only when the identity
proves it is the lifeboat's.

**The general shape: "X is not one of our two things" is a statement about
taxonomy, not about state.** The machine is still in a state, something still has
to name it, and a name nobody writes is a name every reader invents differently.

The cost is written down where an attendee meets it: `lab/01-cluster/verify.sh`
prints "kind lifeboat: module 01 is not gradeable here" and exits 0, because
every check in that file asserts a Talos cluster and there is nothing on the
lifeboat for the attendee to fix. The README and lab 01 both say so.

## RESOLVED — an override for the decision was being read as permission over the record

Round 9, and the top finding of both reviewers. `~/.cloudbox/substrate` answers two
different questions that had been collapsed into one:

* *which substrate should this machine use?* — a **preference**, and
  `CLOUDBOX_SUBSTRATE` is rightly the documented way to overrule it;
* *which substrate is this machine's cluster actually built on?* — a **fact about
  state that exists**, which no environment variable can change.

`substrate_resolve()` answers the first, and every mutating path was using that answer
for the second. So the override became permission to act on the wrong cluster, and each
of these is a real sequence, not a hypothetical:

* `CLOUDBOX_SUBSTRATE=docker ./scripts/destroy-cluster.sh` on a machine recording
  `kind` — the docker teardown found no Talos containers, then removed the lifeboat's
  `/etc/hosts` block and its kubeconfig entries, on a cluster that was still running;
* the same command on a `tbx` machine — deleted `~/.cloudbox/substrate`, the only record
  that those VMs exist, while the VMs kept running and no script could name them again;
* `CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh` on a `kind` machine — walked
  past the by-name refusal (which reads the *desired* value) and persisted `docker` over
  `kind`, after which `--delete` could no longer prove the hosts block was its own;
* `CLOUDBOX_SUBSTRATE=docker ./scripts/install.sh --write-hosts` on a `tbx` machine —
  wrote the exact 127.0.0.1 block the tbx preflight dies on, overriding talos-box's
  resolver so every workshop URL reached the attendee's own loopback.

**The fix is one helper, `require_identity_match <desired>` (`scripts/lib.sh`)**, called
by `create-cluster.sh` (create and `--refresh-endpoint`), `destroy-cluster.sh`,
`kind-fallback.sh` and `install.sh --write-hosts`/`--add-hosts` — in every case **before**
a backend is sourced and before any state is touched. A valid recorded identity that
differs from the desired one is a `die` naming the teardown command for what is
*recorded*, then the create command for what was *asked for*. `substrate_decide_into`
keeps env-first semantics unchanged: the decision is still the attendee's; only acting on
state that disagrees is refused.

Deliberately **not** relaxed by `CLOUDBOX_IGNORE_TBX=1`. That flag exists for exactly one
condition — "tbx is installed but cannot be inspected" — and identity is not an
inspection result; it is something these scripts wrote down themselves. (Round 9's minor
list proposed the flag as an escape hatch for `kind-fallback.sh` over a persisted `tbx`;
the controller ruling supersedes it, and the refusal there is unconditional.)

A machine with **no** record is unaffected, which is what CI is: no
`~/.cloudbox/substrate`, `CLOUDBOX_SUBSTRATE=docker`, silent pass. An **unreadable**
record is also not a mismatch — `substrate_current()` now warns about it in its own voice
(a 000-mode or root-owned file used to read as "no cluster was ever created") and the
guard treats it as no answer, leaving the run's own preflight to find what is really
there.

## RESOLVED — three ways a lifeboat and a Talos cluster could exist at once

Round 9, and all three are the same shape: a guard that asks about one kind of thing on a
machine that can hold two.

* **`kind_nodes_running()` checked only the control plane.** Every host port the lifeboat
  publishes is mapped from the **worker** container (`extraPortMappings` sit under
  `role: worker` in `kind-fallback.sh`), so a stopped worker means no `*.cloudbox.k8s.test`
  URL resolves to anything — while `install.sh --check` said "running — its ports are
  expected to be bound". It now counts both node containers (`docker ps` filters of the
  same key are OR-ed, so one filter per node and a count of 2 is the assertion), and the
  FAIL names which one is down and why the worker is the expensive one.
* **Neither `substrate_preflight` refused over a kind cluster.** kind's node containers
  carry `io.x-k8s.kind.cluster`, not `talos.cluster.name`, so the docker backend's
  `-aq` filter stepped straight over them; on tbx the lifeboat is invisible to
  `tbx status` and was caught only while its `/etc/hosts` block was still present (a
  declined sudo makes it invisible there too). Both now refuse over
  `label=io.x-k8s.kind.cluster=cloudbox`, running or stopped, and name
  `./scripts/kind-fallback.sh --delete`. `kind-fallback.sh` has refused over Talos
  containers since round 8; this is the other direction, which stayed open.
* **The docker substrate had no host-port scan.** `talosctl cluster create` publishes its
  ten ports *after* creating the node containers, so anything already holding port 80 (or
  a NodePort) fails the create with "bind: address already in use" and leaves containers,
  a Talos state directory and a talosconfig context behind. `kind-fallback.sh` has scanned
  since round 8; the docker backend, which binds the same ten ports, did not. Both now
  call `assert_host_ports_free` over the one list, `cloudbox_host_ports` (`lib.sh`), which
  `install.sh --check` reads too.

## TRAP — `hosts_block_present` compares entries; `hosts_block_text_current` compares bytes

Two predicates, one block, and the split is deliberate — worth writing down because
"they both check the hosts block" is the reading that will collapse them again.

* **`hosts_block_present`** compares only the `127.0.0.1 <name>` **entry lines**
  (through `hosts_entry_lines`, which strips CRs and trailing blanks). Those are what
  resolve names. It is what the writer asks before deciding to write, and what
  `install.sh --check` **FAILs** on: a mismatch here means a name does not resolve, or a
  retired name still does.
* **`hosts_block_text_current`** compares the whole marked block byte-for-byte, comments
  included, and never fails anything — `--check` prints one `info` line suggesting
  `--write-hosts` refreshes the prose.

Byte-comparing the whole block in the failing predicate is a bug this repo has already
shipped twice: the block carries a five-line comment paragraph that is edited whenever the
surrounding scripts change (round 3 edited it twice), and every attendee whose block an
older `create-cluster.sh` wrote was then told their hosts file "carries lines that no
longer belong" — a diagnosis of a problem they do not have, pointing at lines that are
perfectly correct, on the one file where following bad advice is expensive. **The entries
are the contract; the comments are commentary.** A new question about this block belongs
on one side of that line, explicitly.

## TRAP — module 04's Crossplane Function is fetched by Crossplane, not by the mirror

**Pre-existing, deliberate, and not on `images.txt` — recorded here because two
independent reviews have now flagged it as a missing image.**
`gitops/components/crossplane/config/functions.yaml` pins
`ghcr.io/crossplane-contrib/function-patch-and-transform:v0.10.7`, and it is the one
image in the workshop that the offline story does not cover: it is a **package**, pulled
by Crossplane's own package manager from inside the cluster, not an image the kubelet
pulls through the node's containerd registry mirror. Pre-pulling it onto the nodes (or
into `cloudbox-mirror`) does not help the package fetch, so `--set` nothing and mirror
nothing: the file's own header has said so since before this branch, and
`git show main:gitops/components/crossplane/config/functions.yaml` is byte-identical to
what is here.

**How you would notice.** With the WiFi already off, enabling the crossplane Application
leaves the `Function` un-Healthy, the XRD never becomes Established, and module 04 stops
before its first XR. The honest instruction is the one the file gives: **enable crossplane
while internet is still available**, then go offline.

**What would retire it:** mirroring the package into the in-cluster Zot and pointing
`spec.package` at `zot.zot.svc.cluster.local:5000` — rehearsal-validated seeding, tracked
in issue #8. Rehearsal step 12 (offline) now names it explicitly as a thing to *observe*,
because "the offline rehearsal passed" has so far meant "we enabled crossplane before
turning the WiFi off" without anyone writing that down.

## TRAP — the lifeboat's browser is not on the lifeboat

The hostname scheme assumes the browser and the cluster share a machine. In
Codespaces they do not: the preview is
`https://<codespace>-<port>.app.github.dev`, which sends GitHub's own `Host`
header, and every rule in the platform's ingress matches on a
`*.cloudbox.k8s.test` host. **Forwarded port 80 therefore 404s** — on a cluster
where `curl http://gitea.cloudbox.k8s.test` from the codespace's own terminal
works perfectly, because the `/etc/hosts` block create-cluster.sh writes is
inside the container.

The README and lab 00 both said the lifeboat runs "identical" content, and
`devcontainer.json` carried a comment saying the hosts block is "where the
browser preview resolves from — nothing to do on the Codespaces host", which is
the opposite of true. Same class as the lifeboat-needed-the-internet finding
above: nobody opens a browser on the path that only gets used when something
else already went wrong.

**What handles it.** Documentation, not code — the NodePorts are already
forwarded (`.devcontainer/devcontainer.json` `forwardPorts`), and each Ports-tab
entry reaches its service directly with no `Host` header involved. README's
Plan B section carries the table, lab 00 points at it, the `devcontainer.json`
comment is corrected, and port 80's label now says it needs a `Host` header.
Everything that runs *inside* the container — `curl`, `kubectl`, every
`verify.sh` — is unaffected, which is why CI never saw this.

**Retired by:** nothing available to us. Host-based routing plus a browser on
another machine is the shape of the problem; the fix would be a per-service
path prefix, which no other substrate needs.

## TRAP — module 08's golang base is offline on docker, online-only on tbx

`lab/08-portal`'s deploy-from-source walkthrough (and `apps/demo-app`'s own
README) has the attendee `crane copy` the golang builder base into Zot at run
time. Since the adventures landed (issue #193) that image IS on
`scripts/images.txt` — `public.ecr.aws/docker/library/golang:1.25-alpine@sha256:…`,
digest-pinned — so on **docker/kind** the copy reads
`localhost:5001/docker/library/golang:1.25-alpine` from the crane mirror and
needs no internet.

On **tbx** it does. tbx's store is keyed by registry, and the only slice the
host can reach with a plain `crane` (no `?ns=`) is the docker.io listener on
`172.30.<n>.1:5055` (`TBX_MIRROR_DOCKERIO_PORT`); a `public.ecr.aws` image sits
in a namespace crane cannot name. Module 08's README therefore tells a tbx
attendee to copy it from `public.ecr.aws` directly — a going-deeper path most
will not take, and the lab says to do it at home if the venue's WiFi is hostile.

**What to keep true.** Everything on the core path stays offline (principle 2);
this is a stretch path. Re-pinning the base as `docker.io/library/golang` would
make it offline on tbx too through `:5055` — at the price of a second copy of
the same bytes on the docker path — measure before deciding. CI
(`bootstrap-test.yaml`) runs the same `crane copy` on a runner that does have the
internet, which is why the deploy-from-source job proves the pipeline but not
the offline story.

## TRAP — recovery tooling that lies is worse than recovery tooling that breaks

The first four rehearsals found recovery paths that **broke**. The recovery pass
found recovery paths that **lie**, which is harder to notice and worse to hit:

- `destroy-cluster.sh` cleaned `~/.kube/config` and left `admin@cloudbox` in the
  pinned `cloudbox.conf`, still selected, pointing at a dead API server — so
  modules 03–10 reported `❌ FAIL: ArgoCD app 'cnpg-operator' is 'missing' — did
  you cp … and push?` to someone who simply had no cluster (`db58fc8`).
- `kubeconfig_in_use()` guessed the wrong file in three places, because a mise
  shim overrides an inherited `KUBECONFIG` — which made `install.sh --check`
  **exit 1 on a machine where all 19 apps were green and every lab passed**
  (`c34c653`, `c7f5ca8`).
- In an untrusted clone the context guard said *"no current context … Build one:
  ./scripts/create-cluster.sh"* against a healthy 19/19 cluster — the exact
  confident wrong answer its own comment says it must never give (`baf52ed`).

All three failed **closed** — no API call against a foreign cluster, nothing
applied, the maintainer's kubeconfig byte-identical across four destroys, four
creates, two kind clusters, nine catch-ups and a mirror purge. The bug each time
was the *diagnosis*, not the action. In a workshop that teaches people to check
what a tool tells them, tooling that is confidently wrong about a working machine
is the failure mode to hunt first.

## TRAP — a green `bootstrap-test.yaml` means "the workshop works on Linux"

`bootstrap-test.yaml` runs on `ubuntu-latest`, where the host routes straight
into the Talos docker network. **macOS, Windows, and every Docker
Desktop / OrbStack / Colima host does not** — and macOS is a fully supported
platform in the published matrix (`docs/PRINCIPLES.md` §12) on which most of a
JavaZone room will be sitting.

**It does not prove the first-party image offline path either.** `bootstrap-test.yaml`
builds `cloudbox-portal` / `-uploader` / `-resizer` / `-grafana` into the mirror as
**`v0.1.0`** while every manifest pins **`v0.2.2`**, so the node's mirror lookup misses and
the pull silently falls through to GHCR — over the runner's excellent internet. Green
therefore says nothing about whether those images are reachable with the network cut, which
is the one thing that matters at the venue. Long-standing (it predates the substrate work)
and left alone deliberately: the tags are `release-please`-managed and not hand-editable
(see the release-please entry below). Rehearsal step 7 is the only place this path is
actually exercised.

**Rehearsals 1, 2 and 4 have each found a workshop-stopping bug that CI cannot see,
and every one of them was in the recovery path** — the second cluster of the day,
`catch-up.sh`, a create→destroy→create loop, and `catch-up.sh` again. (Rehearsal 3's
worst finding, the context near-miss below, was in the same blind spot on the
post-destroy path.) Say it plainly, because it is the strongest generalisation this
project has earned: a CI runner creates exactly one cluster, runs the labs forward
once, and is then discarded, so the *entire* "something went wrong, get me back on
track" surface is untested **by construction**. That is also the surface reserved for
people who are already in trouble.

**And four rehearsals have now separated the two halves of this project.** The
platform repeats itself run after run — Cilium 1.20.0 four times, Kourier's
8 × `[::]:9000` four times, local-path v0.0.37 four times, RustFS at 2.69 MiB/h with
a 4,158-byte longest line four times, one root and zero orphans in the capstone
trace three times. Nothing in four runs has suggested the *platform* is fragile.
What keeps breaking is the **recovery and setup paths**: the second cluster, the
rebuild, the reset laptop, the clone. Budget the rehearsal time accordingly — the
forward path is the part that has stopped paying for itself.

**Rehearsal 1 — the two blockers CI could not see:**

- **`create-cluster.sh` could not finish on macOS at all** (fixed `1129983`).
  `talosctl cluster create` merges a working kubeconfig
  (`https://127.0.0.1:<published port>`); the script's very next line,
  `talosctl kubeconfig --force`, overwrites it with the machine config's
  `cluster.controlPlane.endpoint` = **`https://10.5.0.2:6443`**, an address
  inside the Talos docker network. Linux routes there, laptops do not, so every
  `kubectl` call blocks. Cilium never installs; nothing past module 01 happens.
  Worse, the wait loop had no `--request-timeout`, so `kubectl` blocked on the
  ~75 s OS TCP connect timeout per attempt: `seq 1 60` × `sleep 2` promised
  "2 minutes" and was really ~77 minutes of frozen terminal with no error. Fixed
  by pointing kubeconfig at `docker port <cp> 6443/tcp` (talosctl already puts
  `127.0.0.1` in the API server certSANs, so it is valid on Linux too) plus
  `--request-timeout=5s` so the timeout matches its message. **Rehearsal 2 ran it
  cold and unattended and it holds: 2:09 on the first attempt, nodes Ready at 52 s
  of age, kubeconfig at `https://127.0.0.1:54854` with `10.5.0.2:6443` nowhere in
  it, and the retry loop never even engaged because the API was already up.** But
  rehearsal 2 also found the blocker still armed elsewhere — see below.
- **`destroy && create` failed on the second cluster of the day** (fixed
  `3a7848f`). `talosctl config remove` **refuses to remove the currently-selected
  context and still exits 0** ("skipping removal of current context …"), and
  `destroy-cluster.sh` discarded its output — so the context was never removed,
  the next `talosctl cluster create` found the name taken and renamed **the new**
  context to `cloudbox-1`, and every `talosctl --context cloudbox` in
  `create-cluster.sh` then dialled the destroyed cluster (`connection refused`,
  exit 1, before Cilium). This broke `catch-up.sh --rebuild`. **Proven fixed in
  rehearsal 2, on the very run where it used to appear:** `✅ talosconfig context
  removed` is now true, `talosctl config contexts` afterwards shows exactly one
  `cloudbox` pointing at the *new* cluster's port, there is no `cloudbox-1` rename
  and no `connection refused`, and the second `create-cluster.sh` of the day got all
  the way past Cilium.

**Rehearsal 2 — one more blocker, same blind spot:**

- **`catch-up.sh` deadlocked against itself on modules 07–10** (fixed `92aac7a`).
  Step 5 blocked until **every** Application listed in `solutions/module-N/apps/`
  was Synced+Healthy, and only then (step 6) ran `post.sh`. From module 07 on that
  list includes `demo`, whose `hello-site` Deployment references
  `localhost:30500/hello-site:v1` — an image that exists **only after `post.sh` runs
  the in-cluster build**. On a fresh cluster zot is empty, so `demo` sat in
  `ImagePullBackOff`, the gate died at ten minutes (`❌ Application 'demo' is still
  'Synced Degraded' after 10 minutes`), and the step that would have produced the
  image never ran. Re-running did not help — the second run hits the same gate.
  Affected `catch-up.sh` 07, 08, 09 and 10, with and without `--rebuild`.
  `solutions/module-07/post.sh`'s own header comment already described the symptom
  ("hello-site deployment stays in ImagePullBackOff until the workflow has pushed
  the image"); only the ordering never accounted for it. Fixed by depending on the
  *platform* components instead: wait for the platform apps → run the post-steps →
  then wait for `demo`, which is what the post-steps produce. `catch-up.sh 10` then
  exited 0 in **4:13** on a twenty-minute-old cluster and an eleven-module
  `verify.sh` sweep on it came back **11/11 exit 0**. **No CI job runs
  `catch-up.sh` at all** — and neither did rehearsal 1.
- **Green CI is not evidence about *timing*, either** (fixed `ca4859e`).
  `wait_for_cr`'s `kubectl wait --for=condition=Established crd/$name` on a CRD that
  does not exist yet does not wait — `kubectl wait` on a **named** object returns
  `Error from server (NotFound)` immediately, which under `set -euo pipefail` kills
  the caller. It killed `lab/06-serverless/solve.sh` outright, before the ksvc or the
  cold-start curl. The trigger is structural, not bad luck: `wait_app` deliberately
  returns on **Healthy alone** (requiring Synced was a recurring flake), so an
  Application can legitimately still be `OutOfSync` with its CRDs unapplied at the
  moment `wait_for_cr` runs, and the wider the sync wave the likelier it is.
  `wait_for_cr` is used by modules 03, 04 and 06. CI runs every `solve.sh` and had
  never hit it. Fixed by polling `kubectl get crd/$crd` into existence (60 × 5 s)
  *before* waiting on `Established`.

**Rehearsal 4 — two more, same blind spot, and one of them ours:**

- **A deleted Docker VM left a Talos state directory that nothing removed** (fixed
  `218a248`) — `create-cluster.sh` died in 2 s and `destroy-cluster.sh` said
  "nothing to destroy" and exited 0, an infinite create→destroy→create loop at
  module 01. Its own entry is below.
- **Every clone of the platform repo was an untrusted mise config** (fixed
  `87231be` + `f64d319`), so `catch-up.sh` — which `cd`'d into one — would have
  polled an empty string for ten minutes and then declared a *converged* cluster
  broken, on every module. Its own entry is below too. **We introduced that one
  ourselves, in `e292e25`, fifteen minutes before the run started** — it is the
  parent of the commit the rehearsal ran on.

Note the age of what broke. One bug was minutes old; the other was a gap in scripts
rebuilt five weeks earlier that nothing had ever walked into, because every previous
rehearsal reached `create-cluster.sh` through a `destroy-cluster.sh` that had
containers to destroy. Neither is a place a green pipeline would have looked.

**The standing lesson, now thrice-earned: rehearse on a Mac before the event, and
specifically rehearse the *recovery* — the second cluster, `catch-up.sh <n>`, a
laptop whose Docker VM has been reset, and a fresh clone — not just the forward
path.**

**Half of that is now automated** (`ae224f4`): `bootstrap-test.yaml` grew a
`recovery-path` job that creates a cluster, runs the real attendee command
`catch-up.sh 07 --rebuild`, and destroys it again — asserting exactly one selected
`cloudbox` context with no `cloudbox-N` rename, that `create-cluster.sh` never had to
print its stale-context self-heal warning (which would otherwise *mask* a
`destroy-cluster.sh` regression), that a final destroy of a live cluster leaves zero
contexts and zero node containers, and that `hello-site` rolled out with `demo`
Synced/Healthy — i.e. the post.sh-before-demo ordering, asserted at the end state.
Module 07 because the deadlock lived there and it needs no first-party images.

**The other half is still open: there is no macOS job.** Both of rehearsal 1's
blockers were macOS-shaped, the `recovery-path` job runs on `ubuntu-latest` like
everything else, and the platform most of the room will be on is still covered only by
a human rehearsing before the event. Green CI is now evidence about Linux, forwards
*and* backwards — and nothing else.

## RESOLVED — a deleted Docker VM left a Talos state directory that nothing removed

**Found in the first two seconds of rehearsal 4, fixed in `218a248`.** Kept because
the loop it produced is the worst shape a module 01 bug can have: two commands that
each look like they worked, forever.

`talosctl cluster create` keeps a provisioner **state directory** at
`~/.talos/clusters/<name>` (its `--state` flag; default `$HOME/.talos/clusters`). It
lives on the **host**, not in Docker. So `colima delete`, Docker Desktop's *Reset to
factory defaults*, a hand `docker rm` of the node containers, or a create that dies
after PKI generation all leave it behind with no containers to match it. Rehearsal 4
was the first run ever to start from a deleted VM — 0 images, 0 containers,
0 volumes — and it broke module 01 immediately, on a `state.yaml` written hours
earlier that named two container IDs which no longer existed:

    $ ./scripts/create-cluster.sh
    ⚠️  Removing a stale talosconfig context 'cloudbox' (no such cluster is running)
    ==> Creating Talos cluster 'cloudbox' …
    creating state directory in "/Users/hans/.talos/clusters/cloudbox"
    failed to initialize provisioner state: state directory … already exists,
    is the cluster "cloudbox" already running? remove cluster state with
    talosctl cluster destroy                              ← exit 1, after 2 seconds

**The blocker is the next command, not this one.** talosctl's message points at
`talosctl cluster destroy`, and the workshop's wrapper for that gated on node
containers existing — so it printed `⚠️  No 'cloudbox' cluster found — nothing to
destroy`, `✅ Done. Recreate with: ./scripts/create-cluster.sh`, **exited 0**, and
left `~/.talos/clusters/cloudbox/` exactly where it was. create → fail → destroy
(says it worked) → create → fail, with nothing in the labs, the scripts or the hints
naming the state directory. Module 01, minute 20 of 240, on the machine of anyone
who has ever reset Docker because "Docker was being weird" — which is a very common
thing to do the morning of a conference.

**Why the repo nearly had this covered: it already self-heals the sibling.** The stale
*talosconfig context* branch (`3a7848f`, itself a rehearsal-2 blocker) fired
correctly on the way in, one line above the failure. Same failure, different noun,
and nobody had thought of the noun — because every previous rehearsal reached
`create-cluster.sh` through a `destroy-cluster.sh` that *had* containers to destroy,
which clears the directory as a side effect.

**Fixed the same way and in the same two places as the sibling:** one
`talos_cluster_state_dir()` in `scripts/lib.sh` so the path is written down once,
`create-cluster.sh` removes a stale directory once it knows there are no node
containers, and `destroy-cluster.sh` removes it **unconditionally** — a no-op after a
real `talosctl cluster destroy`, and the entire point when there was nothing to
destroy. Proven on the machine that produced the bug (`✅ Talos cluster state
directory removed`, `~/.talos/clusters/` empty), and the run then built three
clusters on that laptop without touching it again.

**CI cannot see this either, for the reason above:** neither `bootstrap-test.yaml`
nor its `recovery-path` job can produce the state "no containers, but state on
disk" — a runner is discarded, not reset. If you ever need to reproduce it by hand:
`docker rm -f cloudbox-controlplane-1 cloudbox-worker-1` and then run
`create-cluster.sh`.

## RESOLVED — destroy-cluster died on the only context it exists to remove

**Found by reading the nightly on 2026-08-24, fixed in `867aef5`.** A sibling of the
state-directory bug above, in the same script, on the same recovery path — and the
sibling's own fix comment (`3a7848f`) is what it hid behind.

The block that switches away from the `cloudbox` talos context before removing it
starts by finding another context to switch *to*:

    other="$(talos_contexts | grep -vx "${CLUSTER_NAME}" | head -1)"

When `cloudbox` is the **only** context, `grep -vx` matches nothing and exits 1. A
bare assignment inherits its command substitution's status, so under `set -euo
pipefail` the script died on that line — one line above the `else` branch written
for precisely that case, which removes the talosconfig outright. `catch-up.sh
--rebuild` had by then destroyed the cluster and removed the kubeconfig entries, and
never got to recreate anything:

    ✅ Cluster destroyed
    ✅ kubeconfig entries removed (/home/runner/.kube/cloudbox.conf)
    ##[error]Process completed with exit code 1        ← nothing recreates from here

**One cluster and one talos context is the ordinary attendee state.** Anyone whose
`~/.talos/config` held nothing else — i.e. everyone who has only ever run this
workshop — had a documented recovery command that destroyed and then quit. The
maintainers could not hit it: a laptop that has met any other Talos cluster has a
second context, takes the working branch, and never sees it.

**The job built to catch exactly this caught it on its first run.** The
`recovery-path` job (`ae224f4`, added 2026-08-18, itself a rehearsal-2 lesson: *rehearse
the second cluster*) is a fresh runner, so it is always the one-context case. It went
red on the first nightly it ever ran — 2026-08-24 — which is the whole argument for
that job existing: the bug was already on `main`, shipped, and invisible to every
other check we have.

**Fixed by matching contexts in pipe-free bash** (`has_talos_context`,
`first_other_talos_context`) rather than piping into `grep`. That also retires a
latent `pipefail`+`SIGPIPE` false negative in the neighbouring `grep -qx`, where
`grep -q` exits at the first match and `awk` takes `EPIPE` — measured at ~5000
contexts before it can fire, so nobody would have hit it, but it is the same class
and would have been the next thing copied. Verified across all six permutations:
sole `cloudbox`, `cloudbox` first / last / middle of several, no `cloudbox`, and an
empty talosconfig.

## RESOLVED — a reachable mirror is not a mirror that has the image

**Found in the nightly rehearsal, fixed in `510cfb1`.** Module 07 seeds Zot with the
base image its Dockerfile builds `FROM`, sourcing it from the local cloudbox-mirror
so the venue's rate-limited Docker Hub is never touched. It decided the mirror was
usable by asking it `/v2/`:

    if curl -fsS "http://${MIRROR}/v2/" >/dev/null 2>&1; then

`/v2/` answers **"some registry is listening on :5001"**. It says nothing about what
is in it. A mirror that is up but unfilled — a bare `docker run registry`, a purged
`cloudbox-mirror-data` volume, a `cloudbox-init.sh` that was interrupted — answers
that question yes, and `crane` was then pointed at a tag that is not there:

    Error: fetching "localhost:5001/library/busybox:1.37.0": MANIFEST_UNKNOWN:
    manifest unknown; unknown tag=1.37.0

with the Docker Hub fallback four lines below, unused, because *reachable* had
already been answered. The wrong question, confidently answered — the same shape as
the entries above, in the seeding path rather than the diagnosis path.

**Fixed by probing the manifest itself** in both copies (`lab/07-ci/solve.sh` and the
catch-up path in `solutions/module-07/post.sh`), so the question asked is the one
that matters. Verified against real registries: tag present → 0, tag missing → 1,
repo missing → 1, no registry at all → 1 and instant, so the probe cannot hang a lab.

**The CI mirror was seeded with busybox in the same commit, and that is the more
important half.** CI's mirror deliberately holds only the first-party images, so the
probe fix alone would have turned the nightly green *through the Docker Hub
fallback* — the runner has internet, so the substitution is invisible. That would
have left the offline path attendees actually run untested until the venue WiFi was
the thing under test. See the `bootstrap-test.yaml` trap above: this is that trap
with a different noun.

## RESOLVED — the drift gate cried wolf, on the only machines that run it

**Found while verifying the two fixes above, fixed in `57d3f43`.** `check-consistency.sh`
check 9 compares the workshop kubeconfig path in `mise.toml` against the one in
`context-guard.sh`, normalising mise templating to shell templating inline:

    "${mise_kc//\{\{env.HOME\}\}/\$\{HOME\}}"

That replacement is **bash-version-dependent**. Bash 5 consumes the backslashes and
yields `${HOME}`; bash 3.2 keeps them and yields `$\{HOME\}`, which can never equal
the guard's value. So the check reported drift that did not exist:

    ❌ FAIL: the workshop kubeconfig path has drifted: mise.toml says
       '{{env.HOME}}/.kube/cloudbox.conf', context-guard.sh says '${HOME}/.kube/cloudbox.conf'

Those two strings *are* the same path, which is the tell. **macOS `/bin/bash` is
3.2** — this repo supports it deliberately (`check-upstream.sh` has a `no readarray`
note) because attendees run it — so the false failure landed on maintainers running
the gate locally, while CI's bash 5 stayed green and made it look real. A green CI
plus a red laptop reads as "the laptop is out of date", so the honest response is to
go hunting for drift that was never there.

**Fixed by normalising through variables**, which behaves identically on both. Proven
both directions on bash 3.2: clean on the current tree, and still failing when drift
is injected (`mise.toml` pointed at a different filename → `❌ FAIL`) — a gate that
stops crying wolf is only worth anything if it still barks.

## RESOLVED — on tbx the context guard checked a /16, and a stopped cluster was told to destroy itself

Two halves of the same morning: the laptop was rebooted, and the tbx cluster is
still there but not running.

**The guard's half.** `workshop_api_server` accepted **any**
`https://172.30.<n>.<h>:6443`, on the reasoning that 172.30.0.0/16 is
talos-box-owned and RFC1918. That is a *range*, not a cluster — and the guard's
entire job is to refuse the other cluster on this same laptop. Two tbx clusters
are both inside it, and so is a stale `admin@cloudbox` context whose VM's vmnet
**DHCP lease has since moved to a different VM**, which is precisely the
scenario the create path's stale-context reaper exists for. `create-cluster.sh`
now records the address it left the API server on in
`~/.cloudbox/api-endpoint`; the guard accepts a 172.30 address only when it
**equals** that record, and refuses — naming the file — when there is none.
Fail-closed on tbx costs one command; failing open costs someone else's cluster.
`destroy-cluster.sh` forgets the file with the substrate file, for the same
reason.

**The lease moves, and that is normal.** A node's address is a vmnet DHCP lease
keyed by MAC (which is why `tbx_node_ip` reads it and never computes it), so
after `tbx cluster start` the control plane can come up somewhere else in the
/24 — leaving the kubeconfig pointing at a dead address, the talosconfig context
pointing at it too, and the guard refusing an address it has no record of. One
command repairs the **client-side** files:

    ./scripts/create-cluster.sh --refresh-endpoint

It re-reads `tbx status` and rewrites three things: the kubeconfig's `server`,
the `cloudbox` talosconfig context's `endpoints`/`nodes` (baked at create time by
`talosctl config endpoint|node` — miss it and `talosctl --context cloudbox
dashboard` keeps dialing the dead address long after kubectl is well), and, only
after **both** clients have answered at the new address, `~/.cloudbox/api-endpoint`.
Nothing else — no create, no Helm, no `/etc/hosts`. It is tbx-only (on docker the
API server is published on loopback and cannot move), and it dies without writing
anything when the kubeconfig in use has no `admin@cloudbox` context.

**What it does not repair, and we have not proven we need to:** the machine
config's own `cluster.controlPlane.endpoint`, baked by `talosctl gen config` at
create time. A control plane that comes back on a new address still holds the old
one in its config; kubelet/etcd on a single-CP cluster reach the API server
locally, so nothing in three rehearsals has needed it — but no rehearsal has
actually *moved* a lease either. Treat "one command repairs everything" as
unproven until a real lease-move rehearsal says so; the honest claim today is
"one command repairs the three client-side files, and both clients are verified
before it says so".

**The other half — "destroy first" for a cluster you want to keep.** The tbx
preflight and `lab/01-cluster/verify.sh` both treated "a cloudbox cluster
exists" as one state and said *run destroy-cluster.sh*. A cluster whose nodes
are all `stopped`/`suspended` — a reboot, a `tbx down` — is not that state: it
is a cluster waiting to be started, and destroying it costs the attendee
everything they built plus 20 minutes. Both now read the node phases from `tbx
status -o json` (`stopped` | `suspended` | `unreachable` | `maintenance` |
`configured`, `internal/daemon/phase.go`; `PhaseSuspended` is a stopped node
with saved memory) and, when nothing is running, say

    tbx cluster start|resume cloudbox
    ./scripts/create-cluster.sh --refresh-endpoint

Both are real upstream verbs (`cmd/tbx/main.go`: `cluster
create|start|stop|suspend|resume|destroy|list`), and they are **not**
interchangeable. A `suspended` node holds its RAM in a save file; `cluster
resume` restores it, while `cluster start` is a deliberate cold boot that
discards those saves (`internal/daemon/operations.go`, the `discardSavedState`
loop in the start op — "start is a cold boot: suspended memory left by an
earlier suspend is superseded by these launches"). Both leave a running cluster,
so the wrong verb never looks like a failure — it silently throws away the
suspend and takes the slow path. The preflight, `verify.sh` and `solve.sh` pick
the verb from the phases (`tbx_restart_verb`), defaulting to `start`, because
`resume` on a plain stopped cluster is an error. An unreadable or empty status is
*not* "all stopped" — absence must never become advice to start something.

**Retired by:** nothing. Both are properties of running real VMs on a laptop
that gets closed at the end of the day.

## RESOLVED — the workshop scripts ran against whatever cluster `kubectl` pointed at

**Found in rehearsal 3, closed in `2b8de71` (lab/) and `b4f5e2d` (scripts/ +
solutions/), and the residual retired in rehearsal 4** — which reproduced rehearsal
3's exact sequence on a real multi-context kubeconfig and got a refusal instead of a
grade. Kept in full: the near-miss is the evidence, and the mechanism is still the
only thing between a hurried attendee and their employer's cluster.

`destroy-cluster.sh` removes the `admin@cloudbox` kubeconfig entries. `kubectl` then
falls through to the next entry in the same `~/.kube/config` — and this audience
arrives with a dozen. On the ordinary attendee path, `lab/01-cluster/verify.sh`
printed

    ✅ kubectl reaches the API server
    ❌ FAIL: want 2 Ready nodes, have 36/36

against a real **36-node corporate cluster** at `https://172.16.4.2`. `verify.sh`
only reads, so nothing was harmed. Nothing else on the list only reads.

**The second commit is the one that mattered.** The first guarded 18 lab scripts and
left `scripts/` alone, where the exposure is worse: `bootstrap-gitops.sh` makes 13
`kubectl` calls and installs Gitea **and** ArgoCD, `seed-gitea.sh` force-pushes the
platform repo and applies the root app-of-apps, `catch-up.sh` and the
`solutions/module-*/post.sh` it invokes rewrite the platform. The same fall-through
would have installed **a complete GitOps control plane into an employer's cluster**.

**It refuses rather than warns, and has no environment override** — the outcome it
prevents is applying workshop manifests to someone's employer's cluster, and an
override is precisely the line that gets copy-pasted past a safety check by someone
in a hurry in a conference room. It asserts the context **name** *and* the **API
server address**, because neither is sufficient: a name is one `rename-context` from
wrong, and minikube, k3d and Docker Desktop are all on loopback too. Both cases were
proven with fixtures — a context *named* `admin@cloudbox` pointing at a remote server,
and a legitimate local `minikube`. It reads the kubeconfig only and makes no API
call, so a merely stopped workshop cluster still passes and module 01 keeps its own
"kubectl cannot reach the cluster" diagnosis.

**Three placement facts, each enforced by `check-consistency.sh` rather than
remembered:**

- **It cannot fire on source in `scripts/lib.sh`.** `create-cluster.sh` and
  `kind-fallback.sh` source lib.sh and legitimately run *before* any workshop context
  exists — they create it. lib.sh only *defines* the guard; check 8 fails if it ever
  calls it.
- **`catch-up.sh` guards AFTER its `--rebuild` branch.** In front of it, the one
  command reserved for people already in trouble would refuse on the very cluster it
  is about to replace. Check 8 compares the line numbers.
- **`destroy-cluster.sh` is deliberately NOT guarded** — it is what *causes* the
  fall-through, so it must work when the context is already wrong. Safe only because
  nothing in it resolves through the current context: `talosctl cluster destroy
  --name` is scoped by container label, and its `kubectl` calls edit *named*
  kubeconfig entries. Check 8 asserts that premise, so the exemption cannot quietly
  grow a real cluster call.

**One copy of the guard, in `scripts/context-guard.sh`,** shared by `scripts/lib.sh`
and `lab/common.sh`. Folding it into lib.sh was tried and rejected on evidence:
lib.sh defines `ok()`/`fail()`, and `lab/01-cluster/verify.sh` defines its own
*counting* `fail()` **before** sourcing `common.sh` — lib.sh's version would have
clobbered it and module 01 would print `❌ FAIL:` lines while exiting 0.

**The other half of the fix landed in `e292e25`:** `mise.toml` pins `KUBECONFIG` to
`~/.kube/cloudbox.conf` for this repo, so on an activated machine the workshop cluster
is the *only* thing in the file kubectl reads and a destroy leaves nothing to fall
through to. The guard is unchanged and stays — it is the only protection for a shell
the pin never reached (mise not activated), and it is what catches the one state the
pin introduces: the cluster created through `mise run` while a self-installed `kubectl`
in the same terminal reads `~/.kube/config`. That state is diagnosed by name now
("do NOT rebuild"), `install.sh --check` fails on it, and `dev-setup.sh` offers the
shell activation that prevents it.

**The one unproven link in that pin is now proven, by talosctl's own output.** The
worry was that `talosctl cluster create`'s internal kubeconfig merge might ignore
`KUBECONFIG` and leave a stale `admin@cloudbox` at `https://10.5.0.2:6443` in
`~/.kube/config` — an address the guard *accepts*, so a dead cluster would have
looked alive to it. Rehearsal 4 ran three real creates with the pin in effect:

    waiting for all k8s nodes to report schedulable: OK
    merging kubeconfig into "/Users/hans/.kube/cloudbox.conf"

— printed by talosctl itself, before `create-cluster.sh`'s own merge step runs. And
the negative, which is the half that matters: `~/.kube/config` was **byte-identical
across the entire create** (md5 `b97b6342…` before and after, mtime untouched, 33
contexts before and after, **0** occurrences of `cloudbox`, **0** of `10.5.0.2`), and
still identical after three creates, three destroys, the whole 00→10 path and a
`catch-up.sh 10 --rebuild`. **The feared failure mode does not exist.** talosctl
v1.13.8 respects the variable; `talosctl kubeconfig --force` and `kubectl config`
already did.

**And `destroy-cluster.sh`'s surgery on the real file is exact.** The one time it
did modify `~/.kube/config` in that run it was by design — a stale `admin@cloudbox`
from an earlier cluster was sitting in it, and leaving it there re-arms the very
fall-through the pin exists to disarm. Diffing context names before and after:
**exactly one line removed, 34 → 33**, 13 lines, `current-context` untouched. (The
file's md5 also moved once for a reason that was not us at all — a `kubectx` switch
onto a GKE cluster in the same second the maintainer's own shell wrote
`~/.kube/kubectx`. Worth knowing only as measurement hygiene: on a live maintainer
laptop, "the kubeconfig changed" is not evidence that the workshop changed it —
diff the context names, do not compare hashes.)

**The residual this entry carried is discharged.** It asked for one thing —
rehearsal 3's actual sequence, re-run after the fix, on a laptop with a real
multi-context kubeconfig — and rehearsal 4 ran it: `destroy-cluster.sh`, then
`lab/01-cluster/verify.sh`, in an un-activated shell with a **real** `kubectl` first
on `PATH` (a mise shim would re-apply the pin and hide the difference) and
`KUBECONFIG=~/.kube/config`, whose current context was the same 33-context file's
genuine corporate cluster:

    ❌ FAIL: expected 2 running Talos node containers, found 0 — run ./scripts/create-cluster.sh
    ❌ FAIL: refusing to touch this cluster — the current context is 'nav-management-v2',
             which is not this workshop's.
      current context : nav-management-v2
      API server      : https://172.16.4.2
      expected        : admin@cloudbox (or kind-cloudbox) on https://127.0.0.1:<port>
                                                                          exit 1

**No `✅ kubectl reaches the API server`. No `36/36`. No API call at all** — the
kubeconfig's md5 was identical afterwards. The destructive scripts were driven
against throwaway fixtures at the same time: `bootstrap-gitops.sh` and
`seed-gitea.sh` refuse on **both** shapes (a foreign context, and a *workshop-named*
context aimed at a foreign server), `catch-up.sh 3` refuses on the foreign-context
shape — the workshop-named-but-foreign shape was not re-run against `catch-up.sh`,
and is the one gap left in the manual matrix. And create→destroy→create left no
stale entry, no `admin@cloudbox` anywhere in `~/.kube/config`, and no `cloudbox-1`
rename.

**What has not changed: CI still cannot see any of it.** A runner's kubeconfig holds
exactly one cluster, so no job can distinguish a guard that works from one that is
never reached. The evidence is static (checks 7 and 8, nine planted violations shown
to fail), fixture-driven (`--kubeconfig` against synthesised kubeconfigs), and now
one human rehearsal. Re-run that ten-minute check after any change to the guard, the
kubeconfig pin, or `destroy-cluster.sh`.

**One cosmetic wrinkle, on the most-travelled post-destroy path, not fixed.**
`destroy-cluster.sh` removes the cluster/context/user entries from
`~/.kube/cloudbox.conf` but leaves `current-context: admin@cloudbox` dangling, and
`kubectl config current-context` happily returns a context that no longer exists. So
in the *pinned* shell the guard takes its third branch and says "context
'admin@cloudbox' points at an API server it does not name" (API server `<none>`)
rather than the truthful "kubectl has no current context selected". It reads as
"your context is misconfigured" when the fact is "you have no cluster". Exit code and
the paragraph underneath are both right, so nobody is misled for long. Two defensible
one-line cures — `kubectl config unset current-context` in `destroy-cluster.sh`, or a
"context is not in the kubeconfig" branch in the guard — and choosing between them is
a design call, not a defect fix.

## TRAP — a `KUBECONFIG=` prefix does nothing to a mise-shimmed `kubectl`

Not a repo hazard — a maintainer-machine one, recorded because it cost real time and
mutated a live kubeconfig. `~/.config/mise/config.toml` sets
`[env] KUBECONFIG = "{{env.HOME}}/.kube/config"`, which mise applies to **every
shim** — so `KUBECONFIG=/tmp/foo kubectl …` silently uses the real `~/.kube/config`,
including `kubectl config` subcommands, which then *mutate* it. An agent renamed the
maintainer's live workshop context this way. Use `kubectl --kubeconfig=<file>`
exclusively for fixture work: the flag outranks the env var, which is what makes it
safe.

**No longer only a maintainer hazard.** Since `e292e25` the workshop *does* depend on
`KUBECONFIG`: `mise.toml` pins it to `{{env.HOME}}/.kube/cloudbox.conf` for this repo,
so the CloudBox cluster lives in a file of its own and the fall-through above has
nothing to fall through to. The same mechanism therefore now applies to attendees, in
both directions — a mise shim (or an activated shell) will override a `KUBECONFIG=`
prefix inside this repo, and `lab/05-debug-with-ai/make-readonly-kubeconfig.sh` still
prints `KUBECONFIG=$OUT kubectl …` advice that is correct under mise *activation* (a
real binary on PATH) and silently wrong under mise *shims*. Nobody has been bitten by
that yet; `--kubeconfig` would be the robust spelling for the two sanity-check lines.

The same `[env]` block has one more consequence, and it *did* bite — the next entry.

## RESOLVED — the kubeconfig pin made every fresh clone an untrusted mise config

**A regression we introduced ourselves, in `e292e25`, fifteen minutes before
rehearsal 4 started and about ninety before it found it. Script half fixed in
`87231be`, attendee-facing half in `f64d319`.** Recorded plainly, including whose
fault it was, because the shape is one this file already names and we walked into it
anyway: a fix landed in one place (the
maintainer's checkout, which `dev-setup.sh` trusts) and said nothing about its sibling
(every clone of that checkout, which nothing trusts).

**The mechanism.** `seed-gitea.sh` pushes the **whole repository** to Gitea,
`mise.toml` included, so every `git clone http://localhost:30300/cloudbox/platform.git`
carries a copy of the file `e292e25` had just given an `[env]` block:

```toml
[env]
KUBECONFIG = "{{env.HOME}}/.kube/cloudbox.conf"
```

mise's own `trust --help` states the rule: a config holding only `min_version`, plain
`[tools]` and `[tasks]` loads **without** trust; anything with templating does not. A
fresh clone is untrusted by definition, so inside it mise refuses to load the config —
and refuses hard, on every shimmed tool:

    $ cd <clone> && kubectl get nodes
    mise ERROR Config files in <clone>/mise.toml are not trusted. …
    exit=0                                    ← and nothing on stdout

Bisected to the pin rather than to mise: the same clone at `e292e25^` works, HEAD does
not, and HEAD *minus* the `KUBECONFIG` line still fails — the `{{env.HOME}}` in the
**comment** is enough templating to require trust. Both mise modes are affected;
under `mise activate` the `cd` prints `mise WARN … is not trusted` and the tool then
fails the same way.

**Why it was a blocker rather than an annoyance.** `scripts/catch-up.sh` did
`cd "${TMP_DIR}/platform"` at step 3 and made every remaining `kubectl` call from
inside the clone. The failure is silent in the worst available way — exit **0**, empty
stdout — which is exactly what `wait_app_converged` reads:

    from the repo (trusted):    st='Synced Healthy'   rc=0
    from inside the clone:      st=''                 rc=0

So the recovery command would have polled an empty string for its full 600 s and then
declared

    ❌ Application 'rustfs' is still 'missing' after 10 minutes

**on a cluster that had already converged, on every module, for every attendee who
took `dev-setup.sh`'s activation advice** — which the whole kubeconfig design now
depends on. It was found live, not reasoned about: the maintainer's own module 09
hint-5 loop counted zero of five observability apps for ten minutes while all five
went Synced+Healthy in about six.

**Fixed by not `cd`-ing at all.** `catch-up.sh`'s three git calls take `-C`, which is
the pattern the rest of the repo already used — `lab/common.sh`'s `gitops_clone` /
`gitops_push` / `enable_catalog` and all three module 10 `inject.sh` scripts drive the
same clone with `git -C "$CLONE"` and were never exposed. `catch-up.sh` was the only
script that did it the other way. Afterwards `catch-up.sh 9` on the converged cluster
exited **0 in 10 seconds**, ordering intact.

**The other half was prose, and humans do what the prose says.** `lab/02-gitops` and
`lab/10-day2-ops` tell attendees to `git clone … && cd platform` — module 10 four
times — and then run `kubectl` in the same block. `f64d319` appends `mise trust` to
every clone-and-cd instruction, with one explanation of why rather than five. That is
the cheapest of the three options considered; the other two (do not seed `mise.toml`
into Gitea; keep the pin in a file the clone does not carry) both change what
attendees see in their own repo or split the pin across two files, which the pin's own
comment argues against. Module 09 re-enters module 02's clone by path, so it inherits
that trust rather than needing its own line — if module 02's clone path ever changes,
check module 09 with it.

**What to watch:** any future `[env]`, `[hooks]` or template expression added to
`mise.toml` keeps this property. The rule to remember is that **a config we trust on
our own machine is untrusted in every copy of itself**, and a mise shim's failure mode
for that is exit 0 with no output — the single hardest failure to notice in a room of
80 people.

## RESOLVED — a re-injected module 05 fault could leave nothing wrong, and `verify.sh` called it fixed

**Found in rehearsal 2, fixed in `4e2817b`.** Kept because it is the most instructive
failure either rehearsal produced: *a confident wrong answer, produced by the tooling
of the module that exists to teach people not to trust confident wrong answers.*

Sequence: `inject 1-4` → `restore.sh all` → `inject 1-4` again → wait 2.5 min →
`verify.sh` reports

    ✅ fault 01 fixed: deploy/web is Available
    ✅ fault 02 fixed: cluster/orders-db is Ready

while the namespace actually contains the restored pod still serving alongside a
second pod parked in `ImagePullBackOff` forever. Re-applying `issue.yaml` over an
already-restored namespace is accepted and changes nothing, because the state each
fault corrupts is fixed once the object exists:

- **fault 01** is a rolling update to a broken image on a **1-replica** Deployment;
  the default `maxUnavailable: 25%` rounds to 0, so the healthy old ReplicaSet pod is
  never torn down and the Deployment stays `Available` — which is exactly what
  `verify.sh` checks;
- **fault 02** applies a bad `storageClassName`, but `orders-db` already exists with a
  Bound PVC, so CNPG never re-provisions. Its own `fix.sh` **deletes and recreates**
  the cluster: the restore is destructive and the inject is not, and that asymmetry
  *is* the bug;
- faults 03 (CiliumNetworkPolicy) and 04 (mislabelled pod behind the Service) are
  immune — their fault object takes effect on apply regardless of prior state.

So the attendee debugs a cluster with nothing wrong with it, and the module is
explicitly designed to be attempted, abandoned and retried (`inject.sh`'s own closing
line is `Give up / done: ./restore.sh 1`). The **second** attempt is the one that
silently does nothing. It also meant `solve.sh` — the CI regression contract
(inject → verify must fail → restore → verify must pass) — only asserted anything on a
first run against a clean cluster.

**Fixed by refusing the ambiguity:** `inject.sh` now rejects a namespace that already
exists and names the cure, `./restore.sh clean`, which already existed and does
exactly this (verified: after `clean`, all four faults inject correctly, 4/4 caught).
The lesson generalises past module 05 — **an idempotent-looking `kubectl apply` is not
an idempotent *fault*, and a check that looks for a symptom cannot tell "fixed" from
"never injected".** It also generalises to the *Console*, in the next entry, where the
same surging Deployment fooled a different check a day later.

## RESOLVED — a full ready count is not evidence that the release was good

**Found in rehearsal 4, fixed in `024421e`, shipped as `cloudbox-portal:v0.2.2`**
(pinned in `scripts/images.txt` and `gitops/components/portal/portal.yaml`), with a
README follow-up in `858c9e2`. Kept because it is the same mechanism as the module 05
entry above wearing different clothes, and because the *rejected* fix is as
instructive as the shipped one.

With a module 10 scenario injected and `demo-web` visibly in `CrashLoopBackOff`, the
Console's **Components → demo** page read

    Demo workloads   Operational
    … namespace demo · 3/3 workloads ready.

and offered **no Diagnostics panel and no Open investigation button** — so module 10's
centrepiece, "point an AI agent at your own cluster and then verify it", was
unreachable by the path the README tells 80 people to click. `grep -c "Open
investigation"` on the rendered page: **0**.

**The API server was telling the truth.** `handleComponentDetail` gated both the panel
and the Case file on `h.Ready < h.Total`, counted per *workload* — and **a Deployment
surges**. While the new pods crashloop, get OOM-killed at sandbox creation, or cannot
pull, the old ReplicaSet keeps serving every desired replica. Captured live, ten
seconds after `./inject.sh 1`:

    spec.replicas 2 · readyReplicas 2 · replicas 3 · updatedReplicas 1
    unavailableReplicas 1 · Progressing=True/ReplicaSetUpdated,
    lastUpdateTime frozen at the moment the new ReplicaSet appeared

`2/2` ready, forever, on a broken release. Scenario 2 produces **byte-identical
Deployment status** with a benign `ContainerCreating` pod, so an *empty* pod-troubles
list — any fix reasoning from pod state would have missed it. Scenario 3 is healthy
on purpose. The button therefore appeared for none of the three.

**The signal is a gap in progress, not a count.** Kubernetes' own verdict,
`ProgressDeadlineExceeded`, is accepted when it arrives — but it takes **600 s**,
longer than the module, so what actually fires is `Progressing.lastUpdateTime` frozen
for more than `kube.StallAfter` = **120 s**. That number is calibrated, not chosen: on
the same cluster a *healthy* `demo-web` roll is in flight for 14 s and advances its
`Progressing` timestamp every **~6 s**, so 120 s is ~2× the slowest healthy rollout on
record (Backstage, 57 s) and one fifth of the cluster's own deadline. A release in
flight now reads **"Rolling out"** (blue, informational) and only a release that has
gone quiet is Degraded — because the honest answer to a rollout in progress is not
"degraded", and a badge that flaps is worse than one that is late.

**Record the fix that was rejected, because it is the obvious one.** Making the gate
`unhealthy || !diag.Empty()` would have used data already modelled and cost one API
list — and it would have called a **healthy** cluster broken: the diagnostics rollup
includes the namespace's recent `type=Warning` events, and a healthy `demo` carries
stale ones for up to ~17 minutes after a Knative cold start. Warning events are
deliberately not part of the verdict.

**The second condition was separate, and also wrong.** The Case file button hung off
the same health verdict; it now shows on **any component that has workloads**, which
is what makes scenario 3 — a bad release whose pods all come up `Running` — an
investigation at all. The opening prompt no longer asserts "explain why it is
unhealthy" without evidence for it.

**Proven with the fixed binary against the live rehearsal cluster:** a healthy roll →
`Rolling out` for 14 s, back to `Operational`, no Diagnostics panel; scenarios 1 and 2
→ `Degraded`, with the button and the failing container named; scenario 3 →
`Operational`, with the button; each `restore.sh` → `Operational`.

**The backend was never the problem** and this entry should not be read as one: the
same run drove four Case files through `POST /agent/ask` with 200s, 25.8–44.2 s, 2–6
real tool calls and zero error frames. **Only the mount condition was wrong** — which
is why nothing before rehearsal 4 caught it: rehearsals 2 and 3 both drove the agent
through the endpoint directly and neither ever loaded the page the README names.

**Two things to watch.** (1) This needs `cloudbox-portal:v0.2.2` or later; pin an
older image and the symptom returns exactly as written above. (2) `858c9e2` had to
follow, because the README claimed the Diagnostics panel was "already showing your
broken `demo-web`" — with the fix it is *not*, for the first 120 s, and an attendee
staring at a page that looks fine would conclude they had mis-injected the fault. It
is now the teaching beat it should have been: the previous version is still serving,
which is exactly why the ready count cannot see the problem — the same trap the agent
falls into thirty seconds later.

## PROVEN ONCE — the RustFS scanner log flood is fixed, and confirmed on a cluster

Upstream [rustfs/rustfs#5927](https://github.com/rustfs/rustfs/issues/5927).
`nsscanner_disk` omitted `set_disks` from its `#[tracing::instrument]` skip
list, so a `Vec<Arc<Disk>>` was Debug-rendered into every span line — **332,800
bytes per line**, several times a second. From 1.0.0-rc.1 we shipped
`log_level: "info,rustfs_scanner::scanner_io=warn"` to demote just that module.

**Fixed in 1.0.0-rc.2** (released 2026-08-14) by PR
[#5933](https://github.com/rustfs/rustfs/pull/5933) ("skip disk inventory in
scan spans", merged 2026-08-11, commit `727a10e1`, one of the 215 commits in
the `rc.1...rc.2` comparison; issue closed). **Pinned rc.2 and removed the
workaround on 2026-08-16, after re-measuring** — a release note is not
evidence. Idle stdout, our exact config and pod hardening, 300 s windows on the
bench; the last four rows are live clusters, one rehearsal each:

| image | `log_level` | store | idle stdout | longest line |
|---|---|---|---|---|
| `1.0.0-beta.8` | `info` | ~240 objects | 3.26 MiB/h | ~9 KB |
| `1.0.0-rc.1` | `info` | ~240 objects | **30,030 MiB/h** *(orig. pass)* | 332,800 B |
| `1.0.0-rc.1` | `info` | 240 objects | **7,668 MiB/h** *(re-measure)* | 326,600 B |
| `1.0.0-rc.1` | `info,…scanner_io=warn` | 240 objects | 7.35 MiB/h | 3,921 B |
| **`1.0.0-rc.2`** | **`info`** ← shipped | **240 objects** | **5.45 MiB/h** | **4,157 B** |
| `1.0.0-rc.2` | `info,…scanner_io=warn` | 240 objects | 6.37 MiB/h | 4,086 B |
| `1.0.0-rc.2` | `info` | **empty** | 1.21 MiB/h | 4,068 B |
| **`1.0.0-rc.2`** | **`info`** | **on cluster, 247 objects (reh. 1)** | **3.44 MiB/h** | **4,158 B** |
| **`1.0.0-rc.2`** | **`info`** | **on cluster, 244 objects (reh. 2)** | **2.61 MiB/h** | **4,158 B** |
| **`1.0.0-rc.2`** | **`info`** | **on cluster, ~250 objects (reh. 3)** | **2.70 MiB/h** | **4,156 B** |
| **`1.0.0-rc.2`** | **`info`** | **on cluster, 245 objects (reh. 4)** | **2.69 MiB/h** | **4,158 B** |

On rc.2 the workaround measures *worse* than no workaround (6.37 vs 5.45 —
noise): it has nothing left to suppress, which is why it went rather than
being kept "just in case".

Those four cluster rows are the measurement this entry existed to demand, taken after
modules 03/04/09 had put objects in the store, same pod, **0 restarts**, 1–2 h old
each time, on four independently built clusters: rehearsal 1, 247 objects over
60 minutes, **3.44 MiB/hour**; rehearsal 2, cold-built cluster and mirror, 244 objects
over 31.6 minutes, **2.61**; rehearsal 3, ~250 objects over 32.3 minutes, **2.70**;
rehearsal 4, on a brand-new Docker VM, 245 objects over 34 minutes, **2.69**. The
longest line is **4,158 B in three of the four** (rehearsal 3 read 4,156 B), against
the bench's recorded 4,157 B. The #5927 shape (332,800-byte lines) is gone: the
biggest line in half an hour is 4 KB. `rustfs_scanner::scanner_io` is still the
chattiest scanner target — 502 / 504 / 516 / **476** lines per hour across the four —
so the EnvFilter directive would still have something to bite on if it regressed. Over
a 240-minute workshop this is ~11 MiB of container log.

**Four runs, four times the same number, is what this row is really evidence for.**
Not that RustFS is fast, but that the measurement is stable enough that a *different*
number at the next bump means something.

**Two measurement traps, and the first one has now been reproduced in all four
rehearsals — keep this prominent. Window length matters as much as seeding.**
Rehearsal 1: with 247 objects present, a 300-second window read **0.06 MiB/hour**;
30 min → 2.98, 60 min → 3.44; during the 240-object upload burst, 27.8 MiB/h.
Rehearsal 2: a 300-second sub-window *inside* the 31.6-minute measurement read
**0.17 MiB/hour**, 15× below the true rate. Rehearsal 4 reproduced that almost
exactly — 300 s → **0.17**, 900 s → **1.86**, against a true **2.69**.

**Rehearsal 3 is the one to remember, because it broke the mental model:** on a single
log, 300 s read **5.23 MiB/h** (*high* — it landed **on** a scan pass) while 900 s read
**1.85** (low — it landed between them), a 2.8× spread from window choice alone. So the
rule is not "a short window reads low". It is **a short window reads wrong, in whichever
direction the cadence happens to put it**. Measure for half an hour, not five minutes,
and do not trust a `--since=5m` reading in either direction.

**And take the rate from `kubectl logs --since=<window>`, never from a difference of
two totals.** Rehearsal 2's naive byte delta came out **negative** — −3.09 MiB/h, with
the raw log *shrinking* from 3,144,405 B to 1,443,574 B across the window — because
kubelet rotation discarded the `replication_pool` boot burst (below) mid-measurement.
A rate computed from two `wc -c` snapshots is measuring rotation, not logging.

**The lesson that outlives the bug: it only floods once the scanner has
objects to scan.** An empty store reads 1.21 MiB/h on fixed rc.2 and read
2.27 MiB/h on flooding rc.1 — indistinguishable. An empty-cluster smoke test
cannot see this class of bug; an attendee at minute 150 can. Seed the store
first, always.

**Re-check at every RustFS bump** the same way: modules 03/04/09, upload objects,
then watch for half an hour and require single MiB/hour. Not at boot — *after*
objects exist. If it is back, the mitigation history (EnvFilter directive, and
the OTel `filelog` exclusion and `obs_log_directory` options that were rejected
and why) is in `gitops/components/rustfs/VENDOR.md`.

**Do not mistake this for it:** rc.2 still Debug-renders a whole `ECStore`
(disk map and all) into `rustfs_ecstore::bucket::replication::replication_pool`
spans — a **1.5 MB single log line**, same shape of bug as #5927. It is
harmless because it is a *fixed boot cost, not a rate*: measured on the bench at
exactly **7 lines / ~6.2 MB within 9 ms of startup**, and the count stayed at 7
through 240 uploads and 120 s of idle. Rehearsal 1 reproduced it on-cluster —
**6 lines over 100 KB, longest 1,556,132 B, ~6.7 MB in the first seconds** — and
confirmed it does not scale: over the following hour of real traffic no line ever
exceeded 4,417 B. kubelet rotation then discards the burst, so `kubectl logs`
reads 556 bytes a minute later. Worth re-checking only if it ever starts scaling
with operations.

## LIVE — RustFS is a prerelease, by choice

`1.0.0-rc.2` is an rc, on a component modules 03, 04 and 09 depend on. Chosen
deliberately by the maintainer with the above evidence in hand. RustFS is beta
by design in this workshop (`docs/RESEARCH.md` §2); SeaweedFS is Plan B. It held
up in **all four** rehearsals — modules 03, 04 and 09 green every time, on every
cluster they ran on, including both of rehearsal 4's (the forward one and the
`--rebuild`), the same pod alive 1–2 h+ with **0 restarts**,
presigned URLs and the capstone's thumbnail path working, `mb` on an existing bucket
still exiting 0 and `ls` on an empty bucket still behaving as head-bucket — which
settles the log flood, not the prerelease.

#5927 is fixed, but it was a whole-class reminder: if a sibling lands in
another scanner module, the EnvFilter directive that fixed it targets one
module path, not a class of bug, and would need widening.

## UNPROVEN — `bpf.hostLegacyRouting` on tbx, taken on talos-box's word

talos-box's own curated Cilium values set `bpf: hostLegacyRouting: true`
(`internal/manifests/manifests.go:137-138`). Ours did not, and on tbx that is the
setting standing between the attendee's browser and the ingress: the browser is
outside the cluster's L2 segment and reaches the VIP across vmnet, so pod traffic
short-cutting out of BPF instead of going through the host stack is exactly the
path upstream found needed the flag. `create-cluster.sh` now sets it — **on the
tbx branch only**.

What is proven: the chart key exists in the vendored 1.20.0 values
(`values.yaml:716`) and `helm template … --set bpf.hostLegacyRouting=true` renders
`enable-host-legacy-routing: "true"` into the ConfigMap; without the flag the key
is absent. What is **not** proven: that the VIP is reachable from the host with
it, on real hardware. We have never run a tbx cluster.

**Do not copy it to the docker branch.** That path is CI-proven as it stands, the
host reaches the ingress through a published port rather than a VIP, and the flag
costs the BPF fast path for nothing.

**Retired by:** rehearsal step 3 — curl a `*.cloudbox.k8s.test` hostname from the
host against a tbx cluster. If it fails *with* the flag, the next thing to check
is the L2 announcement policy and the pool, not this line.

## PROVEN ONCE — Cilium 1.20.0 datapath comes up on Talos-in-Docker

Everything verified for the 1.19.5 → 1.20.0 bump was static: chart digest
cross-checked three ways, all eight `--set` values confirmed present in the
schema *and* landing in the render, KubePrism intact, capability list exactly
our 11. Nothing proved the datapath — until 2026-08-17, on Talos v1.13.8 /
arm64, in rehearsal 1:

- `wait_rollout kube-system daemonset/cilium` passed **first try, ~50 s**; both
  nodes `Ready` at 61 s of age. `cilium status`: agent, operator and
  `cilium-envoy` DaemonSets all 2/2, 2/2 pods managed, chart 1.20.0.
- `cilium-dbg status` from inside the agent: **`KubeProxyReplacement: True`**
  `[eth0 10.5.0.2 (Direct Routing)]`, `routing-mode=tunnel`/vxlan,
  `ipam=kubernetes`, zero kube-proxy pods, CoreDNS Available.
- KubePrism intact — `KUBERNETES_SERVICE_HOST=localhost` / `_PORT=7445` on both
  the agent DaemonSet and the operator Deployment, `talosctl get
  kubeprismstatuses` → `127.0.0.1:7445 HEALTHY true`. **Those land as env vars,
  not `cilium-config` keys** — worth knowing when checking by hand.
- The **policy** path works too, not just connectivity: module 05's fault 03 is a
  NetworkPolicy fault, and it both enforced while injected and stopped enforcing
  after the fix, inside the verify poll window.

**Rehearsal 2 re-confirmed all of it on a cold cluster**, and then again on the
second cluster of the day: `Cilium: Ok 1.20.0 (v1.20.0-450c5314)`,
`KubeProxyReplacement: True [eth0 10.5.0.2 (Direct Routing)]`, tunnel/vxlan, no
kube-proxy pods, both nodes Ready at **52 s** of age — and module 05's fault 03
enforced and then stopped enforcing again, so the **policy** path is twice-confirmed
too, not just connectivity.

**Rehearsals 3 and 4 make it four for four**, the last of them on a cluster built from
a brand-new Docker VM and repeated on that day's second and third clusters:
`Ok 1.20.0 (v1.20.0-450c5314)`, image `quay.io/cilium/cilium:v1.20.0@sha256:383968cd…`,
`KubeProxyReplacement: True [eth0 10.5.0.2 (Direct Routing)]`, tunnel/vxlan, IPAM
kubernetes, 0 kube-proxy pods, agent/operator/envoy 2/2 each, nodes Ready at 67 s.

Blast radius if a future bump breaks it is still total: nodes never Ready,
`wait_rollout` times out, and nothing else in the day happens. One machine, one
architecture — re-run module 01 on the next bump before believing it again.

## PROVEN ONCE — local-path-provisioner v0.0.37 is still the wave-0 gate

v0.0.37's entire upstream diff is a new health server: port 8080, startup and
liveness on `/health`, **readiness on `/ready`** (a different path — easy to
mis-copy). `bootstrap-gitops.sh` installs this imperatively before GitOps
exists, and everything else queues behind it. If the health server misbehaves,
bootstrap stalls at "Installing local-path-provisioner" and nothing past module
02 runs.

Rehearsal 1, in `bootstrap-gitops.sh`'s 54 seconds: the split is **not**
mis-copied (`startup=/health live=/health ready=/ready`), the deployment went
`Progressing` → `Available` in **~10 seconds** with **0 restarts**, and the PSA
`privileged` namespace label — the curation whose loss makes every PVC hang
Pending — is present. Gitea's 5Gi PVC `Bound` within the same minute. Against
`wait_rollout`'s 300 s × 2 the "probe budget ≈ 65 s" worry is a non-event.

Rehearsal 2 re-confirmed it on a cold cluster in a 1:09 bootstrap: image
`docker.io/rancher/local-path-provisioner:v0.0.37` deployed, `storageclass
local-path` present, wave 0 Synced/Healthy inside module 02's **8-second** solve.
**Rehearsal 4 makes it four for four**, in a 0:51 bootstrap: same image, probe split
still `startup=/health live=/health ready=/ready`, pod 1/1 with **0 restarts** at 82 s
old, the PSA `privileged` namespace label present, and Gitea's 5Gi PVC `Bound` 72 s
after the namespace existed.

## PROVEN ONCE — Knative 1.23.0 kourier, and the IPv6 curation is RETIRED

1.23.0 moves the Envoy **static** stats listener from `0.0.0.0` to `"::"` +
`ipv4_compat: true`. A static listener that cannot bind is fatal at process
start, not degraded: the readiness probe on `:8081` is never reached, the gateway
crashloops, and module 06 loses all ingress. **We curated it back to `0.0.0.0`**
because that failure mode could not be settled by reading YAML.

**With the curation, module 06 worked:** gateway **1/1 within ~20 s** of the pod
appearing, 0 restarts, all five knative-serving Deployments 1/1 within 12 s, and
`curl -H 'Host: hello.demo.127.0.0.1.sslip.io' http://localhost:31080` returned
`Hello your own cloud!` (200, 0.694 s warm); scale-to-zero observed after ~30 s
of silence.

**The curation is gone as of 2026-08-17, and rehearsal 2 re-proved it without the
confound that dogged the first test** — `kourier.yaml` carries upstream's
`"::"` + `ipv4_compat: true` verbatim, and the two `allow` lines for it are out
of the component's ```curation block (kourier.yaml: 8 hunks → 6, gate green).
The circumstantial retire condition was already recorded: inside the gateway pod
`/proc/net/if_inet6` is populated (lo + eth0 `fe80::…`), `bindv6only=0` and
`disable_ipv6=0` on all/lo/eth0, and `argocd-server` on the same cluster and CNI
holds real `[::]:8080` / `[::]:8083` listeners. But that only proved the netns
*would* allow it. **What retires it is the direct test, run on the live rehearsal
cluster** (Talos v1.13.8 / Cilium 1.20.0 / arm64, ArgoCD auto-sync suspended for
the window, the bootstrap ConfigMap applied by hand, the gateway rolled):

- a **freshly created** gateway pod reached **1/1 Running with 0 restarts** on
  the `"::"` bootstrap — no crashloop, no bind error anywhere in its log;
- inside that pod, `awk '$4=="0A"' /proc/net/tcp6` shows **eight
  `00000000000000000000000000000000:2328` rows** — `[::]:9000`, one
  SO_REUSEPORT socket per Envoy worker. **The static listener binds the IPv6
  wildcard here.** That is the fact the curation had made unobservable;
- the IPv4 side is untouched: 8× `:8080`, 8× `:8081`, 8× `:8090` (the dynamic
  xDS listeners) and `127.0.0.1:9901` (admin);
- the stats port still works **over IPv4**, v4-mapped through `ipv4_compat`:
  the OTel Collector's `GET /stats/prometheus` answers **200** with ~197 KB
  every 30 s;
- `curl -H 'Host: hello.demo.127.0.0.1.sslip.io' http://localhost:31080` returned
  `Hello your own cloud!` **200** repeatedly (51 s on the scale-from-zero call,
  then 0.09–2.9 s).

**Rehearsal 2 repeated the whole measurement on a fresh gateway on an unloaded,
cold-built 8-CPU cluster** — no suspended auto-sync, no hand-applied ConfigMap, no
saturated worker — and it came out the same shape byte for byte: **1/1 Running,
`restartCount = 0`**, zero `bind` / "Address family not supported" lines in the log,
**8 × `[::]:9000`** in `/proc/net/tcp6`, the IPv4 side untouched (8 × `:8080`,
8 × `:8081`, 8 × `:8090`, `127.0.0.1:9901`), and `GET /stats/prometheus` over IPv4
answering **200 with 171,452 bytes** through `ipv4_compat`. Module 06 passed 8/8 with
the cold-start curl and scale-to-zero at ~40 s.

**Rehearsal 4 makes it four for four, byte for byte:** `ready=true restarts=0`, zero
bind / "Address family not supported" lines in the log, **8 × `[::]:9000`** in
`/proc/net/tcp6`, the IPv4 side untouched (8 × `:8080`, 8 × `:8081`, 8 × `:8090`,
`127.0.0.1:9901`), module 06 8/8 and scale-to-zero at ~40 s. The
`GET /stats/prometheus` leg was *not* re-run by hand that time — the gateway image has
no `wget`/`curl` and the OTel Collector scrapes it on the same 30 s cadence anyway.

**If this ever regresses, the symptom is immediate and unmistakable:** the
static listener cannot bind → `3scale-kourier-gateway` crashloops at process
start (bind / "Address family not supported" in `kubectl logs`, readiness on
`:8081` never reached) → **module 06 loses all ingress**. The fix is to put
`address: 0.0.0.0` back and drop `ipv4_compat` — but check
`/proc/net/if_inet6` and `bindv6only` in the pod first, because the real question
would be what took IPv6 out of the netns.

**One honest caveat, and one retired.** (1) Still one machine, one architecture, one
CNI version — settled, not proven; re-run module 06 on the next Knative or Cilium
bump. (2) **The confound is gone.** Rehearsal 1's test ran against an already-loaded
cluster where the CPU cap dominated it: the gateway sat in `ContainerCreating` for
~11 minutes on the Cilium CNI ADD and the *old* pod restarted twice on liveness
`504`/timeout while it waited (both exits code 0 "Completed" — kubelet-initiated, not
Envoy). None of that was ever about IPv6, and on the uncapped cluster none of it
happens: the gateway is 1/1 in seconds with 0 restarts. Those old restarts were
evidence for fixing the CPU caps, and the caps are fixed.

## LIVE — VENDOR.md curation lists were wrong 11 times out of 19

A `VENDOR.md` that under-documents its curation is a landmine for the *next*
person to re-vendor: they follow the recipe, lose an undocumented edit, and
break a module silently.

All 19 components have now been audited. **11 were wrong**, and every one of the
first four was found by accident, while bumping that component for an unrelated
reason:

- `local-path-provisioner` — missing the PSA `privileged` namespace label, whose
  loss makes **every PVC hang Pending**
- `knative-serving` — missing the `config-domain` `sslip.io` entry and nine
  `config-observability` keys (module 06 and the module 09 trace waterfall)
- `knative-eventing` — missing six `config-observability` keys
- `nats` — documented about half the component: the whole metrics sidecar, its
  port and annotations, the probe split, the resource blocks
- `grafana`, `otel-collector`, `portal`, `picture-pipeline`, `backstage`,
  `application-xr` — gaps found in the full audit; `portal`'s RBAC list was
  actively stale
- only `cnpg-operator` was complete (it has no curation at all — byte-identical
  to upstream, now stated explicitly)

Two of those were worse than gaps: `backstage`'s VENDOR.md named the **wrong
Gitea admin** (`cloudbox` instead of `gitea_admin`), so a maintainer "fixing"
the manifest to match the doc would have broken the integration; and
`application-xr` documented a curation **that does not exist** (see the
`spec.env` TRAP below).

**The same shape turned up once more in rehearsal 1, in code rather than prose.**
The Console's Workshop page — advertised in `lab/README.md` as "a live dashboard
of which modules your cluster has reached" — could never mark module 04 Done:
`apps/portal/internal/web/workshop.go` listed `WorkshopDatabases` **cluster-wide**
while the portal's only grant is the namespaced Role module 08 hands it, so the
403 zeroed `WDBCount` and the row could score at most 1/2. It read *In progress*
on a cluster with crossplane Synced/Healthy, two Ready WorkshopDatabases and
`lab/04-self-service/verify.sh` at 10/10. Fixed `c1faf23` by scoping to `demo` —
which is what the field's own comment (`// WorkshopDatabases in ns demo`) and the
row's own hint already claimed. It is Go source, so it needed a portal release before
anyone could see the fix — **released as `cloudbox-portal:v0.2.1` and confirmed in
rehearsal 2**: `GET :30600/workshop` renders module 04 as **Done**, with every other
module inferring correctly around it (05 correctly "Manual check", 09 correctly "Not
started" before the capstone ran). The page is not merely rendering, it is inferring.
Rehearsals 3 and 4 both re-read `04 Self-service → Done`, so that fix is three times
confirmed.

**One gap in the same page, unfixed and deliberately small: it stops at module 09.**
`lab/README.md` advertises it as "a live dashboard of which modules your cluster has
reached", it says "Where you are in the 10 modules", and it renders **00–09** — true
if you count 00–09 as ten, and confusing next to a `lab/10-day2-ops` that exists and
has a `verify.sh`. Everything it does render is correct. A content decision, not a
defect, and listed here so the next person does not rediscover it as a bug.

**The shape is always the same:** the doc was accurate the day it was written
and rotted at the next bump, because nothing ever compared it to anything.
Prose cannot stay honest about a file that changes for other reasons — which is
why the re-render gate and token-coverage lint exist. Do not rely on this
audit staying true; rely on the guards.

## LIVE — a wrong-architecture mirror serves happily

`cloudbox-init.sh` now copies tag-pinned images for the host architecture only
(that is what took the pre-pull from ~15.5 GB to ~7.5 GB). The failure mode is
nastier than a missing image: `create-cluster.sh` sets `skipFallback: false`, so
a **miss** is harmless — the node falls back to the real registry. A
**wrong-arch** mirror still answers, so there is no miss, no fallback, and pods
crashloop with exec-format errors. Offline. At the venue.

**Mitigation (shipped):** `install.sh --check` verifies every tag pin's
architecture against the **Docker daemon's** arch — not `uname -m`, because an
x86_64 Rosetta shell on Apple Silicon reports the wrong one.
`images-gate.yaml` separately requires every tag-pinned index to publish both
linux/amd64 and linux/arm64, so an upstream dropping an arch shows up in the
weekly report rather than on a laptop.

**Rehearsal 2 is the first run to exercise this from truly nothing.** The mirror
volume was destroyed before the run, so `cloudbox-init.sh` rebuilt all 66 refs
(3 host + 63 cluster) for linux/arm64 in **one 11:35 pass, 7,254,911,019 bytes RX on
`en0`** — 7.25 GB against the README's published "~7.5 GB (arm64)", so the figure is
honest — with zero warnings, zero retries and zero failures. `install.sh --check` then
reported **mirror arch matches (arm64)** across 62 repositories, and every module
downstream pulled from it. (Rehearsal 1 lost one image to a transient blob fetch and
needed an 11:03 + 2:29 two-pass; that retry gap has since been closed in
`cloudbox-init.sh`, and rehearsal 2 never had to exercise it.)

**Rehearsal 4 went one step colder — a brand-new Docker VM, 0 images, 0 containers,
0 volumes, so the host Docker cache was built from nothing too — and it holds: one
13:39 pass, 66/66 refs, 0 retries, 0 warnings, `mirror arch matches (arm64)` across
62 repositories.** ~100 s of that was the "checking that all 66 refs exist upstream"
preflight.

**But the published figure is now a floor, and it does not include the model — a
documentation debt worth one clause.** RX on `en0` across the pre-pull window:
7.25 GB (reh. 2) → 7.41 (reh. 3) → **7.87 GB (reh. 4)**. `en0` counts all host traffic
in the window, so each is an upper bound on the workshop's own share and the README's
"~7.5 GB (arm64)" is not dishonest — but the trend is upward, and **on top of it sits
the ~1.4 GB `qwen3:1.7b` pull** that `cloudbox-init.sh` performs and the "~7.5 GB" line
does not mention. Every rehearsal machine already had that model, so no run has ever
measured its download. **An attendee doing the documented prework from nothing pays
roughly 9 GB of download**, not 7.5. (Disk lands near the same number by coincidence:
free space fell 101 → 92 GiB across rehearsal 4's pre-pull — a 6.807 GB mirror volume
plus 1.655 GB of host images.) Wording, not code: `lab/00-setup/README.md` and the
script's own size warning.

**The other half of offline-first is the reaches nothing gates, and rehearsal 1
found the earlier leak fix was incomplete.** `solutions/module-07/post.sh`
still copied `docker.io/library/busybox:1.37.0` straight from Docker Hub, and
`solutions/module-{08,09,10}/post.sh` all chain into it — so **every `catch-up.sh`
from module 07 onward** depended on the one registry that is rate-limited at the
venue, on the recovery path, at the venue, for someone already behind. What made
it invisible is that its sibling `lab/07-ci/solve.sh` had *already* been fixed to
source `localhost:5001/library/busybox:1.37.0` from the mirror with a fallback and
a warning: the earlier fix landed in the lab and not in the solution. Fixed
`941d043` by copying that logic verbatim. **When auditing internet reaches, grep
`lab/` and `solutions/` — a fixed lab says nothing about its `post.sh`.** CI never
saw it because CI runs online, where both sources work.

Still open, same class: `install.sh --check` proves the mirror is reachable from
container context with `docker run … docker.io/library/busybox:1.37.0`, which is
in `images.txt`'s `[mirror]` section but **not `[host]`**, so `cloudbox-init.sh`
never `docker pull`s it. Invisible in the documented order (the first `--check` at
home warms the host cache), but it bites anyone whose first `--check` is offline —
including a helper debugging an attendee's laptop in the room. Adding the ~2 MB
image to `[host]` closes it, at the cost of touching the pin surface.

## TRAP — digest-pinned refs must keep the full multi-arch index

Do not "optimize" the digest-pinned refs in `cloudbox-init.sh` the way tag pins
were optimized. A pinned `@sha256:` names the **index**; a platform-filtered
copy stores a different digest, and the node's pull by the pinned digest 404s.

The clever version was tested and rejected: pushing the index byte-for-byte with
absent children works on containerd **1.7**, and fails on containerd **2.2.6** —
which is what Talos v1.13.x ships. containerd 2.x fetches every child manifest
in an index regardless of platform. Passing at home, failing at the venue.

## TRAP — things that look wrong and are not

| Looks like | Actually |
|---|---|
| `KUBERNETES_VERSION` is behind upstream | **Derived** from the Talos release. Raising it makes `create-cluster.sh` request control-plane images that are not in `images.txt` — and every other check stays green. `check-consistency.sh` now asserts the four control-plane refs match. Bump it *with* Talos, never ahead. |
| `docker.io/library/busybox:1.37.00` is a typo | Module 05 fault injection. Deliberately broken, never pre-pulled, excluded by name in `check-consistency.sh`. Never "fix" it. |
| Talos could go to 1.12.x | No. `cni: none` docker clusters hang — talos#12885. |
| kagent's latest release is v0.10.0-beta | Upstream does not mark its beta/rc tags as prereleases. `upstream.list` reads kagent from **tags**, stable-only. |
| CNPG is stuck on 1.28.x | Deliberate hold — the mature minor. 1.29/1.30 exist and are ignored by a `track` regex. |
| envoy is behind at v1.37.x | net-kourier ships `v1.37-latest`; we pin the exact patch it resolves to. A `track ^1\.37\.` regex stops the weekly report recommending 1.39. |
| Backstage is amd64-only | Upstream ships it that way; Apple Silicon runs it emulated. Listed in `MIRROR_ARCH_EXEMPT`. **Rosetta turns out not to be required:** on 2026-08-17 it ran under Colima with `vmType: vz` and **`rosetta: false`** — 1/1, 0 restarts, `:30700` → 200, zero error lines. **And the famous 9-minute start was the CPU cap, not the emulation:** same image, same `vz`/`rosetta: false` Colima, uncapped nodes → **57 seconds** to Ready in rehearsal 2, a 9.5× improvement from a change that has nothing to do with Backstage. Keep the "start it early" guidance in module 08 as a **4-core** caveat, where the old number will still roughly apply; on 8 cores it is now over-cautious. |
| module 10 scenario 3 never shows `ImagePullBackOff` — anywhere, even offline | Correct by design **on docker/kind** (on tbx, since #206, the store is keyed by registry, the `docker.io` ref is a MISS that falls through to Docker Hub, and offline it IS `ImagePullBackOff` — the scenario briefing tells both stories and `verify.sh` accepts both), and for a **deeper reason than the `skipFallback: false` fallback** everyone assumed. `cloudbox-init.sh` stores mirror content under the **registry-stripped** repo path (`ghcr.io/knative/helloworld-go` → `knative/helloworld-go`) and `create-cluster.sh` points the *docker.io* mirror at that same registry, so the poisoned `docker.io/…` ref with an identical path and digest is a **mirror HIT**. Measured in rehearsal 1: `containerd/v2.2.6` requested manifest and every blob with `?ns=docker.io` and got `200` from `cloudbox-mirror`; pull time 265 ms; the traffic never left the laptop. **Rehearsal 2 confirmed it on a *cold-built* mirror rather than an inherited one:** the pods go straight to `Running` on `docker.io/knative/helloworld-go@sha256:c2b7412f…`, and `verify.sh` asserts the policy violation (full cycle 2:02, then 8/8 after the revert). So the pull succeeds offline too — the failure is reserved for refs the mirror does not carry, or clusters built without the pre-pull. Do not "fix" the manifest, and do not restore an `ImagePullBackOff` expectation to the check: the scenario and `verify.sh` were rewritten to assert the policy violation reaching the cluster instead (see `lab/10-day2-ops`). |
| module 10 scenario 2's poison is `2Mi`, which "cannot be a plausible rightsizing" | Deliberate and calibrated, and it replaced an `8Mi` that produced **no symptom at all**. On containerd 2.2.6 + runc, `helloworld-go` is Ready and restart-free at 4/6/8/12Mi (8Mi survived 300 sequential and 4800 concurrent requests before *one* replica OOMKilled — unusable as a lab), while ≤3Mi never starts. At `2Mi` the sandbox fails in seconds with the runtime naming the cause: `FailedCreatePodSandBox … container init was OOM-killed (memory limit too low?)`. **Re-confirmed live in rehearsal 2:** the symptom arrives on its own in **~75 s** with no load generator (`FailedCreatePodSandBox` ×6, pod stuck `ContainerCreating`), full inject→revert cycle **2:01**, against rehearsal 1's ~25 minutes of failing to make `8Mi` OOM. The scenario now teaches "a limit is the budget your container is created inside", not a `lastState: OOMKilled` cadence — that signature is not reachable with this image without a load generator. Do not raise the value back toward plausible-looking numbers without re-measuring. |
| `kagent-controller` CrashLoopBackOffs ~3× right after you enable kagent | Ordering, not configuration. It runs its DB migration at startup and starts before `kagent-postgresql` has endpoints (`connect: no route to host`), then self-heals — 1/1 within ~40–90 s, app Synced/Healthy, seen in both rehearsal 1 runs and again in rehearsal 2 (restarted 2×, then Healthy). Module 10 now says so in the text and uses it as a teaching moment. Only read the logs if it is still restarting after ~3 minutes. |
| `application-xr`'s `spec.env` does nothing | Correct — it is **RESERVED, not implemented**. The Composition emits no patch for it; the field stays in the XRD so the v2 append lands without an API break. The VENDOR.md claimed for months that it was "appended"; git history shows the patch never existed. The XRD description now says so. |
| `docker.io/grafana/grafana` vanished from `images.txt` | It was only the `FROM` line in `apps/grafana/Dockerfile`, consumed by CI. No pod ever pulled it. The deployed image is `ghcr.io/randax/cloudbox-grafana`. |
| the preflight says `cilium image (default): v1.19.5`, but we pin 1.20.0 | That line is the **cilium-cli's own built-in default**, printed by `cilium version --client`, not our pin. `create-cluster.sh` installs 1.20.0 by explicit `--version` from `versions.env`. Cosmetic, but `dev-setup.sh` and `install.sh --check` both print it, so a wrong version number appears twice in the output everybody reads before module 01. Do not "fix" it by changing the pin. |
| `cloudbox-init.sh` printed the size warning and then `❌ Aborted.` | It prompts for confirmation and read EOF — you ran it non-interactively (`nohup`, CI, a pipe). Pass `--yes`. An attendee running it by hand never sees this; anyone scripting the prework will, and it looks like a failure rather than a prompt. |

## PROVEN ONCE — helm 4 on the apply path

`helm` is pinned to **4.2.4**, used by three real `helm upgrade --install` calls
(Cilium in `create-cluster.sh` and `kind-fallback.sh`, Gitea in
`bootstrap-gitops.sh`). Renders were verified identical to 3.21.3 — crossplane
and gitea byte-for-byte, cilium differing only by three empty-string ConfigMap
keys that helm 4 strips as null chart defaults, functionally inert.

**The 4.2.3 → 4.2.4 patch (2026-08-17) is not render-neutral, and the vendor
gate caught it.** 4.2.4 fixes "vanishing empty lines", which changes *how much
blank line* a chart render carries: `check-vendor-drift.sh` guard 1 went red on
`kagent.yaml` and `rustfs.yaml` with a new hunk id `0972f4d7` — two blank lines
before a `---` where 4.2.3 emitted one — and on `rustfs.yaml` it also *retired* a
curation, because 4.2.4 no longer emits the empty trailing KMS `secret.yaml`
document at all. Same hunks, more of them, on crossplane (9 → 20) and kagent
(21 → 25). All whitespace, no object changed; the allowlists were updated rather
than the manifests re-rendered, and each component's VENDOR.md says so. **The
lesson for the next helm patch: expect the render gate to move, and read the
hunks before blessing them** — a real chart change would arrive looking exactly
the same at first glance.

The untested part is **apply**, not render. helm 4 defaults `--server-side` to
`auto`, which for a *fresh* release — every workshop cluster — resolves to
server-side apply. All three invocations therefore pass **`--server-side=false`**
explicitly, keeping helm 3's proven client-side path, so this is a
same-behaviour-newer-binary bump rather than a behaviour change.

**Both real installs took the client-side path in rehearsal 1, verifiably** (on
4.2.3 — that rehearsal predates the 4.2.4 patch by hours, and nothing in 4.2.4's
notes touches the client-side path; its only server-side change is a *conflict
retry* fix that `--server-side=false` never reaches). After Cilium (module 01)
and Gitea (module 02):

    kubectl -n kube-system get ds cilium -o jsonpath='{…managedFields…}'
    manager=helm operation=Update          # server-side apply would read operation=Apply

Same for `deploy/gitea` in ns `gitea`. Both releases `deployed` at revision 1, no
field-ownership complaints, no `--force-conflicts` needed anywhere. That is
exactly what `--server-side=false` promises, so the bump is confirmed inert on
the apply path as well as the render.

**This is still the first thing to revert if module 01 or 02 misbehaves** — set
`helm = "3.21.3"` in `mise.toml` and drop the three flags. Nothing in the repo
needs a helm 4 feature.

**4.2.4 itself has now run the apply path**, which the paragraph above could not
claim: rehearsal 2 ran on `helm v4.2.4` and both real invocations succeeded on **two**
clusters — Cilium in `create-cluster.sh` (nodes Ready at 52 s, datapath confirmed) and
Gitea in `bootstrap-gitops.sh` (1:09, Gitea and ArgoCD up, 5Gi PVC Bound) — with every
downstream module green. Honest caveat: the `managedFields` `operation=Update` check
was **not** repeated on 4.2.4, so what is proven is "the installs work", not "the
client-side path was taken"; re-run the one-liner above at the next helm bump.

**Retire the flags when:** a full `bootstrap-test` is green with them removed.
Nothing was odd in either rehearsal, so there was nothing to A/B against; the flags
were left in place. On this evidence the experiment looks safe to try, but it is
a separate change, not a side effect of a rehearsal.

## TRAP — Grafana must not be allowed to phone home at boot

`GF_INSTALL_PLUGINS=""` only empties the *user* install list. Grafana separately
background-installs drilldown apps compiled into the binary — 4 on 12.4.5, **6
on 13.1.3** — which offline means six failed calls to grafana.com per pod start,
each landing as `level=error … read-only file system`. `GF_PLUGINS_PREINSTALL_DISABLED=true`
removes all of it. Do not delete that env var; it was already needed at 12.4.5
and 13 made it worse.

Related, deliberate: `victoriametrics-logs-datasource` is held at **0.29.0**
though 0.30.1/0.31.0 exist — all three declare `>=10.4.0`, so nothing forces a
move and holding keeps the Grafana major a one-variable change.

## RESOLVED — the Console's Case file could not read kagent 0.9.12's stream

**Fixed in `cloudbox-portal:v0.2.1`; proven rendering in rehearsal 2.** The frame
shapes below are kept because they are the only written record of what kagent 0.9.12
actually emits, and the next portal or kagent bump has to hold against them.

Module 10's second half is "open an investigation in the Console and watch the
tool-call log". Against the pinned kagent **0.9.12** that surface used to produce
exactly one thing: *"Investigation failed — the agent responded in a format this
console doesn't recognize. Check that your kagent version matches the workshop pin."*
— a message that sent the attendee after a version problem that did not exist.

**The run was always fine; the translation was not.** Driven end to end in rehearsal 1
(the Console's own endpoint, `POST /agent/ask` for `demo/Component/demo-web`,
scenario 1 injected), the controller answered `200` after **87 s** and the agent
really worked:
`k8s-agent` logged `POST http://host.docker.internal:11434/api/chat 200` and a tool
call to `kagent-tools`. Capturing the raw A2A stream from the controller
(`POST /api/a2a/kagent/k8s-agent/`, `message/stream`) shows why the console sees
nothing — the frame shapes kagent actually emits are:

    result.kind = "status-update"   … status.message.parts[].kind = "data",
                                      data = {name, args, id}          ← tool call
    result.kind = "status-update"   … data = {name, id, response:{content:[…]}}  ← tool result
    result.kind = "status-update"   … status.message.parts[].kind = "text"       ← narration
    result.kind = "artifact-update" … artifact.parts[].text                      ← final answer
    result.kind = "status-update", final = true                                  ← terminus

`apps/portal/internal/kagent/kagent.go`'s `translate()` accepted top-level
`kind: "message"`, `"tool-call"` and `"tool-result"` — kagent emits none of those,
so every frame was dropped, `emitted == 0`, and `agent_ask.go:233` rendered the error
card. The code's own comment (`reconcile against live kagent at rehearsal — see
spec #133 rehearsal gates`) marked this exact gate; rehearsal 1 was that
reconciliation, and it failed.

**Fixed in the portal, exactly there:** `translate()` now reads tool steps out of
`status-update.status.message.parts[].data`, narration out of its `text` parts, and
the answer out of `artifact-update`. Shipped in `ghcr.io/randax/cloudbox-portal:v0.2.1`
and **driven through the Console's own endpoint in rehearsal 2**, against kagent 0.9.12
with host-side `ollama 0.32.14` / `qwen3:4b`:

    HTTP 200, 2,468 bytes, 126 s
    event: tool_call     k8s_get_pod_logs(container=web, namespace=demo,
                                          pod_name=demo-web-…, tail_lines=50)
    event: tool_result   ↳ listen tcp: lookup tcp/8080-canary: unknown port
    event: message       (narration)
    event: verdict       Status / Hypothesis / Kill-test / Fix cards
    event: done

**Zero error frames, `emitted > 0`**, and the verdict names the real cause — the
non-numeric port `8080-canary` — from evidence the agent actually fetched rather than
from restating the symptom. That is the "one investigation renders tool calls and a
verdict in the browser against kagent 0.9.12" this entry's *retires when* clause asked
for. `lab/10-day2-ops/README.md` was corrected in `4e2817b`; the old symptom survives
there as a one-line "if you see this, your portal image predates v0.2.1".

**Unplanned teaching bonus, worth keeping:** the agent's *Fix* card is wrong in
**method** — it proposes `kubectl get deployment demo-web -o yaml > demo-web.yaml &&
sed -i … && git push`, i.e. dumping live state into a file instead of reverting the
offending commit in `gitops/components/demo/demo-web.yaml`. Correct diagnosis, wrong
hands. That is principle 9's "verify the agent" in one screenshot, for free.

**Watch on the next bump:** the translation is coupled to undocumented A2A frame
shapes. If a kagent bump changes them, the symptom is the same error card, and the
diagnosis is to capture `POST /api/a2a/kagent/k8s-agent/` `message/stream` again and
compare against the table above.

## PROVEN ONCE — the kagent inference path, and what is still unproven

Rehearsal 1 could not exercise this at all (no `ollama` on the host, so
`cloudbox-init.sh` warned and skipped the model pull). Re-driven the same day against
the still-running cluster, with `ollama 0.32.14` installed from Homebrew and
`qwen3:4b` pulled — and then re-run end to end **through the Console** in rehearsal 2,
where `cloudbox-init.sh` also found the host model and reported
`✅ Host-side Ollama model qwen3:4b is ready for kagent`:

- **Host reachability works, including the default loopback bind.** A pod resolved
  `host.docker.internal` → `192.168.5.2` (Colima `vmType: vz`) and got
  `{"version":"0.32.14"}` from `/api/version` with Ollama listening on
  **`127.0.0.1:11434` only** — Colima proxies it, as Docker Desktop does. No
  `OLLAMA_HOST` change needed on macOS.
- **The default ModelConfig resolves and the model answers.** `provider: Ollama`,
  `model: qwen3:4b`, `num_ctx: 64000`, unchanged from the chart: `k8s-agent` logged
  `POST http://host.docker.internal:11434/api/chat 200`.
- **Beat 1 flails exactly as the module claims.** One real tool call
  (`k8s_describe_resource`, which returned), then a *printed* `<function-call>` block
  naming a pod that does not exist, then the symptom restated as a cause. No second
  tool call. 87 s wall clock.
- **The model switch beat 2 teaches is real and fast.** One field pushed to Gitea
  reached `modelconfig/default-model-config` in **20 s**; kagent rolled a new
  `k8s-agent` pod; the newly named model loaded in Ollama and answered
  (`POST /api/chat 200`, 25 s). Proven by switching between two *local* models.
- **The honest-spec line now has a number.** `qwen3:4b` at the chart's
  `num_ctx: 64000` costs **~11.5 GiB** on the host — 2.4 GiB weights, **9 GiB KV
  cache** — measured from Ollama's own memory breakdown. The context window, not the
  4B of weights, is what does not fit beside a 16 GiB Colima VM. A 7–8B model at the
  same context asked for 7.8 GiB and Ollama evicted the previous model to get it
  (`system_free 3.3 GiB, system_limited=true`).

**SUPERSEDED on 2026-08-18 by measurement, in both halves — read the entry below.**
The 11.5 GiB number was right and the diagnosis ("the context window, not the weights")
was right; the *fix* was not "live with it". `num_ctx` came down to **16384** and the
model to **qwen3:1.7b**, and the pin is now `qwen3:1.7b` + `num_ctx: 16384` +
`num_predict: 1200`.

**WATCH — the residue, in the order it would bite:**

1. ~~**The Console surface is broken.**~~ **Retired.** Everything above was originally
   driven through logs and the raw A2A stream; rehearsal 2 drove a full investigation
   through the Console's own `POST /agent/ask` against `cloudbox-portal:v0.2.1` and got
   `tool_call → tool_result → message → verdict → done` with zero error frames, in
   **126 s** (against the raw-stream run's 87 s — the Console path is not free).
2. **Beat 2's actual provider is untested.** No OpenCode Zen key existed, so
   `provider: OpenAI` + `baseUrl: https://opencode.ai/zen/v1` + `apiKeySecret` has
   never been exercised — nor has the Anthropic fallback. The *switch* is proven; the
   *endpoint, secret plumbing and auth* are not. Zen's free tier is also explicitly
   time-boxed and may simply be gone.
3. **Native Linux is unproven twice over:** the `10.5.0.1` ModelConfig edit, and the
   fact that a loopback-bound Ollama cannot be reached across a plain bridge (module
   10's README now says to use `OLLAMA_HOST=0.0.0.0` there — untested).
4. **The "16 GB does not fit" claim is still a claim.** It was measured on a 32 GB
   Mac; the 11.5 GiB figure supports it arithmetically, nothing has run it on a
   16 GB machine.
5. **`cloudbox-init.sh` skips the model pull silently-ish** if Ollama is not
   installed *yet* when module 00 runs — which is the likely order for an attendee
   who installs it after reading module 10. The README now says to check
   `ollama list`.

**Retires when:** ~~one investigation renders in the browser~~ (done, rehearsal 2),
and one beat-2 run against a hosted provider returns a verdict. Only the second half
is outstanding.

## RESOLVED — beat 1 took the laptop apart, and `num_ctx` was 75% of the reason

**Fixed on 2026-08-18** (`qwen3:1.7b` + `num_ctx: 16384` + `num_predict: 1200` in
`gitops/components/kagent/kagent.yaml` and `KAGENT_OLLAMA_MODEL` in `versions.env`).
Rehearsal 3 ended a clean module 10 end state — 21/21 apps, 73 pods,
`/proc/pressure/cpu some avg10=3.10` — and then ran two Case file investigations against
host `qwen3:4b`. Pressure went to **93.48**, host load average to **86**, ~25 pods into
liveness restart loops, module 09's Broker to `EndpointSlicesUnavailable`, five apps out
of Synced+Healthy. `ollama stop` recovered it in 62 s, so it was a resource conflict, not
a wedge.

**The arithmetic, from Ollama's own memory breakdown** (M1 Max, 32 GB, 16 GB Colima VM,
21 apps + 76 pods running):

| model / `num_ctx` | `ollama ps` | weights | KV cache |
|---|---|---|---|
| `qwen3:4b` / **64000** (chart default) | **12 GB** | 2.68 GiB | **9000 MiB** |
| `qwen3:4b` / 32768 | 7.5 GB | 2.68 GiB | 4608 MiB |
| `qwen3:4b` / 16384 | 5.1 GB | 2.68 GiB | 2304 MiB |
| `qwen3:4b` / 8192 | 3.9 GB | 2.68 GiB | 1152 MiB |
| **`qwen3:1.7b` / 16384** (the pin) | **3.4 GB** | ~1.4 GiB | 1792 MiB |
| `llama3.2:3b` / 16384 | 4.0 GB | ~2.0 GiB | 1792 MiB |

**A smaller model alone would barely have helped.** The KV cache is **75% of the 12 GB**;
the 4B of weights is 2.7 GiB of it. `num_ctx` is the lever, and the model size is the
second one — 12 GB → 3.4 GB, i.e. **8.6 GB handed back to macOS**, is both together.

**`8192` is disqualified, not merely tighter.** One `k8s_get_events` result on this
cluster is **~8.2 k tokens on its own** (measured: `task.n_tokens = 8194` on the second
turn), so the agent overflows its own context the first time it reads events. **16384 is
a floor.**

**The second finding is the one nobody was looking for: `kagent-controller` 0.9.12 cuts
the A2A stream at a hardcoded 180 s.** Three runs ended at `duration 180.04 / 180.01 /
181.39` on `POST /api/a2a/kagent/k8s-agent/`, and the Console renders that as
*"The investigation didn't complete … SSE stream error: context deadline exceeded"*.
The portal's own `Timeout: 6 * time.Minute` (`apps/portal/internal/kagent/kagent.go:120`)
is **not** the binding limit and never was — it is twice the real ceiling. There is no
flag, arg or env for the controller's 180 s in chart 0.9.12; re-check it at the next
kagent bump. The failure mode that reaches it is always the same: a small model handed a
large tool result generates without stopping (runs past **9,000 tokens in one turn** were
recorded). `num_predict: "1200"` is what bounds it, and it is load-bearing.

**Why the model changed too, and it is not the reason you would guess.** At
`num_ctx: 16384`, `qwen3:4b` answered **with no tool call at all in four of five runs** —
straight from the opening prompt to an invented verdict — which renders an *empty* Case
file and costs module 10 its centrepiece. Ten investigations against a live scenario-1
fault, all through the Console's own `POST /agent/ask`:

| model / `num_ctx` / `num_predict` | runs | completed with a verdict | real tool calls | wall clock | hit the 180 s cap |
|---|---|---|---|---|---|
| `qwen3:4b` / 64000 / – | 1 | 0 | 1 | 179 s | **yes** |
| `qwen3:4b` / 16384 / – | 5 | 4 | **0 in 4 of 5** | 95–178 s | 1 |
| `qwen3:4b` / 16384 / 1200 | 3 | 0 | 0–1 | 42–86 s | 0 (truncation broke it instead) |
| `qwen3:1.7b` / 16384 / – | 6 | 3 | 2–6 | 43–184 s | 3 |
| **`qwen3:1.7b` / 16384 / 1200** | **10** | **9** | **4–26** | **31–106 s** | **0** |
| `llama3.2:3b` / 16384 / 1200 | 6 | 6 | 4–18 | 21–33 s | 0 |

`llama3.2:3b` measured slightly better and was **rejected on licence**: Llama 3.2 ships
under Meta's Community License, not an OSI-open one, and "Cloud on your terms" should not
pre-pull a non-open model when an Apache-2.0 one in the same family does the job.

**Beat 1 still flails, and better than before** — 9 of 10 runs. The *shape* changed, so
`lab/10-day2-ops/README.md`'s calibration paragraph was rewritten: it is no longer "one
tool call, then a printed `<function-call>` block". It is 4–26 real tool calls, breadth instead of
depth (one run walked `k8s_get_resources(all_namespaces=true)` across **nineteen**
resource types and never asked the crashing pod for its logs), calls against objects that
do not exist (a pod name passed as a *Deployment*, a `demo` pod looked up in namespace
`default`), a verdict that **narrates the JSON it just downloaded** instead of reading
it — and, once, a verdict diagnosing its own failed tool call as "likely localized to
your environment". **~1 run in 10 it
does land on `PORT=8080-canary`** — and that run also asserted "the Service is configured
to use 8080-canary", which is false. A correct headline with an invented supporting fact
is the best principle-9 artifact this module has ever produced; the README now points at
it directly.

**Criterion 4, live:** three and four back-to-back investigations at the new pin left the
cluster at 21 apps unchanged, both nodes `Ready`, and a cluster-wide **restart delta of
0–2** (against rehearsal 3's ~25 pods in liveness loops). VM memory pressure peaked at
`some avg10=37`, never below **7.0 GB** available inside the VM. VM *CPU* pressure is
**not** a usable discriminator on the machine this was measured on — two identical
`qwen3:1.7b` batches twenty minutes apart peaked at 39.2 and 92.9 because the host was
also running Zoom, Slack and a photo-library index; the idle control over the same
cluster read `some avg10=3.92`. The footprint numbers in the first table are the
deterministic evidence; treat the pressure numbers as this-machine-that-afternoon.

**Rehearsal 4 ran the whole beat end to end at the new pin, and it costs the cluster
nothing measurable.** Four back-to-back investigations through the Console's own
`POST /agent/ask` against a live scenario-1 fault, on a module 10 end state of 21 apps
and 66 pods:

| | rehearsal 3 (`qwen3:4b`, `num_ctx 64000`) | **rehearsal 4 (`qwen3:1.7b`, `num_ctx 16384`)** |
|---|---|---|
| investigations completing with a verdict | — | **4 of 4**, 200 each, 25.8–44.2 s |
| real tool calls per run | — | 2–6, **0 error frames** |
| runs hitting kagent's 180 s cut | — | **0** — the slowest was a quarter of the ceiling |
| `ollama ps` | 12 GB | **3.3 GB**, 100% GPU, context 16384 |
| `/proc/pressure/cpu some avg10` peak | **93.48** (avg300 78.06) | **28.16** (avg300 peak 6.46) |
| `/proc/pressure/memory some avg10` peak | 50.65 (`full` 3.61) | **0.94** (`full` ~0) |
| VM memory available, minimum | (host had 57 MB free pages) | never below **7,575 MB** |
| pods entering liveness restart loops | ~25 | **0** |
| cluster-wide restart delta over the batch | ~25 | **1** |
| ArgoCD apps leaving Synced+Healthy | 5 | **0** |
| nodes | worker `NotReady` | **2 Ready throughout** |
| `ollama stop` needed to recover | **yes** | **no — nothing to recover** |

The liveness cascade is simply gone — **and beat 1 is still beat 1**, which is the
other half of what had to hold. Rehearsal 4's first run made two real tool calls that
both returned, including `k8s_get_pod_logs` on the crashing pod (the log line naming
`PORT=8080-canary` was *in its hands*), and then narrated the events JSON instead:
*"No Failures … the logs indicate a normal operation, and no issues are detected"* —
about leftover helper pods, while `demo-web` crashlooped throughout, with empty
Kill-test and Fix cards. That is the README's calibration paragraph, live.

Same caveat as above on the pressure numbers — the host's load average ran 15–31
through that batch because it was doing other work — so read the restart delta, the
app count and the node states as the deterministic evidence, and the pressure figures
as corroboration.

**Retires when:** ~~one full rehearsal runs module 10 beat 1 end to end at the new
pin~~ (done, rehearsal 4, on the deterministic evidence — the host was not idle), and
one run happens on a **16 GB laptop**. That second half is the whole of what is left:
"beat 1 does not fit on 16 GB" is *still* a claim, now with 3.4 GB in it instead of
11.5 GB, and no rehearsal machine can answer it.

## PROVEN ONCE — smaller things the rehearsals settled

Unlabelled rows are rehearsal 1; rehearsal 2's re-confirmations are marked inline.

| What | What was measured |
|---|---|
| **NATS 2.14 liveness** | Ready **2/2 in 25 s**, 0 restarts, `/healthz` and `/healthz?js-enabled-only=true` both `{"status":"ok"}`, JetStream up, PVC Bound (rehearsal 2: 2/2, 0 restarts, ~25 s again). **And the premise was wrong:** `local-path` is a hostPath bind that does not enforce the 1Gi request — inside the pod `/data` reports the node's whole 97.9 G — so "a full PVC CrashLoops the pod" needs the *node* disk to fill, not the PVC. Much less reachable than feared, and also: nothing bounds JetStream's growth. |
| **BuildKit v0.32.2, module 07** | `moby/buildkit:v0.32.2-rootless` came up **2/2 in 15 s** and the workflow reached `Succeeded` inside the 91 s solve, on kernel 6.8.0-117 arm64 / containerd 2.2.6, PSA-privileged `builds` namespace. No runc or rootlesskit trouble at all. Rehearsal 2 re-ran the whole chain on a cold cluster, twice (module 07 and again through `catch-up.sh`), and the build Succeeded first try both times. |
| **zot v2.1.20 under chart 0.1.122** | Tag override in effect (`:v2.1.20` over the chart's declared v2.1.18), 1/1 in 16 s. **Anonymous push works** — `crane copy --insecure` with no credentials — and `:30500` answered 200 on `/v2/`, `/` (UI extension) and `/v2/_zot/ext/search` (GraphQL). One non-finding: `/v2/_zot/ext/discover` **404s** at 2.1.20; that endpoint does not exist there, the extensions are plainly enabled. Rehearsal 2 re-confirmed the anonymous `crane copy` seed and the catalog read on a cold cluster. |
| **Grafana Explore deep-link** | **This was not an unproven nicety — it was broken.** Anonymous Viewer does not carry the `datasources:explore` RBAC action (26 actions, without it), so Grafana answered every `/explore…` request with `302 → /?redirectTo=…` and, since an anonymous session never logs in, **discarded the `panes` payload entirely**: every Console deep-link landed on the Grafana home page. `/` and `/dashboards` returning 200 is what made it easy to miss. Fixed in `d608d88` with `GF_USERS_VIEWERS_CAN_EDIT=true` (marked load-bearing in the component's VENDOR.md) and verified served: bare `/explore` **200**, deep-link **200**, `datasources:explore` granted, `dashboards:write` still denied (27 actions), the `panes` JSON parses, its uids resolve, and both carried expressions return data through the proxy (`sum(k8s_pod_cpu_usage{k8s_namespace_name="observability"})` → 0.0623, `sum(cnpg_backends_total{cnpg_cluster="my-db-pg"})` → 1). **Still one human click from "renders prefilled"** — neither rehearsal had a browser, and rehearsal 2 did not re-check it at all. (`GF_AUTH_ANONYMOUS_ORG_ROLE=Editor` is the one-line alternative; it grants more than Explore.) |
| **OTel 0.158.0 deprecation WARNs** | **The count was wrong: 4 on the agent, not 3.** Gateway is 5 as predicted (`otlphttp` ×3, `spanmetrics`, `servicegraph`); the agent emits `otlphttp` ×2, `kubeletstats` **and `filelog`**, identically on both DaemonSet pods — so **13 cluster-wide**, once at startup each. Legacy IDs stay on purpose: renaming makes the config unloadable on 0.149.0, breaking rollback. Pre-empt the corrected count in the module 09 text. |
| **Module 09 trace waterfall** | **One connected trace: 37 spans, exactly 1 root, 0 spans with a missing parent** — `cloudbox-portal POST /gallery/upload` → activator → uploader → `s3 put original` → `broker.ingress` → in-memory channel → `broker.filter` → activator → resizer → `s3 download` / `decode and resize` / `s3 upload thumbnail and meta`. It does not fragment: the re-applied `config-observability` keys (nine in serving, six in eventing — the curation the VENDOR.md audit found missing) are what buys this. VictoriaTraces knew all 10 services. Whole observability stack Synced/Healthy in ~90 s. **Rehearsal 2, cold cluster: 122 spans, still exactly 1 root (`POST /gallery/upload`), still 0 orphans**, 9 services in the trace and 10 known to VictoriaTraces; five observability apps Synced/Healthy in 2:06. More spans, same shape — the property is the root/orphan count, not the span count. |
| **Argo Workflows v4.1.1** (rehearsal 2) | The bump was made on static evidence; a real rootless BuildKit build now backs it. `workflow-controller:v4.1.1`, workflow **Succeeded**, `hello-site` in the zot catalog and serving, and the pod layout is `init=init, containers=wait,main` — **the legacy init+wait layout is intact**, which is what rootless BuildKit depends on. v4.1.0's opt-in `initlessPod` did not arrive with the bump: `grep -rn initlessPod gitops/ --include='*.yaml'` → **0 hits**. |
| **`catch-up.sh` as a rebuild path** (rehearsal 2) | After the `92aac7a` fix, one `catch-up.sh 10` on a cluster that had not existed twenty minutes earlier reproduced the entire workshop end state in **4:13**: 19/19 Applications Synced+Healthy (module 10's canonical set), 63 pods all Running or Completed, and an eleven-module `verify.sh` sweep at **11/11 exit 0**. The two `○` star tasks are correctly *not* restored — they are human moments, and both `verify.sh` scripts say so and pass anyway. |
| **`catch-up.sh 10 --rebuild`, the whole recovery command** (rehearsal 4) | **The first successful `--rebuild` in four rehearsals** — R1 never ran it, R2's died at 12:01 on the `92aac7a` deadlock, R3 skipped it for disk. **Exit 0 in 7:07**: destroy + create + `bootstrap-gitops` + `seed-gitea` + force-push module 10's canonical state + converge 18 Applications + `post.sh` (a real in-cluster BuildKit build, with busybox coming from the **mirror**, so `941d043` holds) + converge `demo`. End state **19/19 Synced+Healthy, 63 pods**, both nodes Ready at 6 minutes old, kubeconfig invariants intact (no `cloudbox-1` rename, `~/.kube/config` untouched), and an eleven-module sweep at **11/11 exit 0 on a cluster that had not existed seven minutes earlier**. `nats` and `backstage` are correctly absent — catalog extras, not the canonical set — and because a rebuild starts from a fresh cluster there are no orphaned Application objects, so the `platform` root is Synced/Healthy rather than permanently `OutOfSync` as it is on the non-rebuild path. |

**Louder than any of those 13 one-shot WARNs, and unresolved:** the OTel gateway
logs a **failed Prometheus scrape every 30 s, forever**.
`net-kourier-controller` ships the `prometheus.io/scrape` annotations and
declares port 9090, but Knative 1.23 moved its metrics to the OTel pipeline and
opens nothing there — so `connection refused`, one target, one WARN per interval.
Harmless, permanent, and the only *recurring* error-shaped line in the stack.
Silencing it needs either a curation dropping the upstream annotation or a drop
rule in the receiver; both are curation decisions nobody has taken. **Not re-checked
in rehearsal 2** — nothing suggests it changed, and the same goes for the OTel WARN
counts above.

**Rollback hazards:** downgrading the OTel Collector below 0.156 needs
`/var/lib/otelcol` wiped. The kagent whitespace normalization produces a large
git diff that is a cluster no-op.

## TRAP — release-please cannot write `.github/workflows/**`

`GITHUB_TOKEN` is not permitted to modify workflow files. Adding one to
`extra-files` fails the whole run at tree creation with a bare
`Error adding to tree`. Do not put a workflow file in that list.

Separately: "GitHub Actions is not permitted to create or approve pull requests"
is a **repo setting**, not a code problem. It silently failed every release-please
run from 2026-07-19 until it was ticked on 2026-08-11.

## TRAP — the release/pin publish window (recurs every release)

A release PR rewrites all 15 first-party pins to the next version, but those
images only exist **after** the PR merges and `build-images` finishes. In
between, `images.txt` points at images that do not exist and
`cloudbox-init.sh`'s preflight fails, downloading nothing.

Hit once for real on 2026-08-11 (`cloudbox-grafana:v0.1.0` did not exist) and
navigated deliberately for v0.2.0 on 2026-08-16. **This is not a bug to fix —
it is inherent to pinning your own images.** The rule is procedural: merge the
release, wait for the build, verify every ref resolves, *then* pre-pull.

    while IFS= read -r ref; do crane manifest "$ref" >/dev/null 2>&1 \
      || echo "MISSING: $ref"; done < <(grep -vE '^\s*(#|\[|$)' scripts/images.txt)

Never hand a fresh laptop a pre-pull inside that window.

## RESOLVED — the AWS CLI is gone; s5cmd does the S3 work

**Decided and shipped 2026-08-17, and exercised end to end in rehearsal 2** — which
was the first run to take the new code path on a cold cluster, twice.
`public.ecr.aws/aws-cli/aws-cli:2.36.24` was
used by modules 03, 04 and 09 and by the platform-api / application-xr bucket
Jobs, with **no rationale recorded anywhere**. The choice was between writing the
rationale down and changing the tool; the tool changed, to
**`docker.io/peakcom/s5cmd:v2.3.0`**.

**The deciding reason was honesty, not size.** A sharp attendee asks "why am I
typing `aws` in a workshop about *not* using AWS?", and the only true answer was
"nobody wrote it down". The lesson the call sites exist to teach is *RustFS
speaks the S3 API, so standard S3 tooling works against it unchanged* — and a
vendor-neutral client makes that point better than the vendor's own CLI, which
invites exactly the wrong inference. The labs now say so where an attendee reads
it (module 03 hint 4, module 09 hint 3), and module 09 names the third client in
the same story: the uploader and resizer talk to the same bucket with
`minio/minio-go`. Three clients, one API, indistinguishable to the server.

The size was the tiebreak, and it is not small: **12 MiB compressed on arm64
against 129 MiB** (`crane manifest … | jq '[.layers[].size]|add'`), on a
component every attendee pre-pulls. `rclone` (~30 MiB) lost because it needs its
own `RCLONE_CONFIG_*` idiom; s5cmd reads the **same** `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` / `AWS_REGION` and takes `--endpoint-url`, so every
credential block in the Jobs and compositions carried over byte-for-byte. `mc`
was never in the running — MinIO's community edition being discontinued is the
reason RustFS is here at all.

**Two things that were expected to be hard and were not.** They are recorded
because the *next* person to touch this will assume the same things:

- **The image is not FROM scratch.** It is `alpine-minirootfs-3.20.3` + the
  single binary (3 layers, `crane config … | jq .history`), so `/bin/sh` →
  busybox 1.36.1 is present and `command: ["/bin/sh","-c"]` works exactly as it
  did with the AWS CLI. There was no need for two containers, sequential
  commands, or s5cmd's `run` subcommand. **What *is* different: `ENTRYPOINT` is
  `/s5cmd`**, so `command:` must override it, `PATH` does not contain `/`, and
  the binary must be called by absolute path `/s5cmd`.
- **`mb` on an existing bucket exits 0** against RustFS 1.0.0-rc.2, printing
  `mb s3://<bucket>` and, with `--json`, `{"operation":"mb","success":true,…}`.
  So the feared hot-loop (a `restartPolicy: OnFailure` Job retrying a non-zero
  `mb` forever) does not exist here. **The guard was kept anyway**, as
  `s5cmd ls s3://<bucket> >/dev/null 2>&1 || s5cmd mb s3://<bucket>` — because
  that exit 0 is the *store's* `CreateBucket` behaviour, not a promise from
  s5cmd, and RustFS is a prerelease. `ls` on a bucket is a faithful
  `s3api head-bucket`: exit 0 when it exists even if empty, exit 1 +
  `NoSuchBucket` (404) when it does not.

**The one real trap the swap exposed, and it was pre-existing. Reproduced live in
rehearsal 2, against the real store.**
`kubectl run --rm -i --restart=Never` folds the container's **stderr into
kubectl's own stdout** when the container exits before the attach lands — which
a 22 MB Go binary always does, and a Python CLI that takes a second to boot
never did. So `2>/dev/null` on the kubectl side stopped suppressing the client's
error text, and a naive port of module 03's "is the listing non-empty?" check
would have read `ERROR "ls s3://app-assets": NoSuchBucket…` as *objects*, i.e. a
**false pass in a graded check**. Reproduced 5/5. The fix is to stop reading
stream separation as a signal:

- **existence** comes from the **exit code**, which is unaffected (verified 5/5:
  exit 1 for a missing bucket, 0 for an existing one, including an empty one);
- **content** comes from stdout with s5cmd's own `ERROR ` lines filtered out.

`lab/09-capstone/verify.sh` gets this for free, because the reshaped
`list-objects-v2` equivalent —
`s5cmd ls --show-fullpath "s3://images/<prefix>" | sed -n 's|^s3://images/||p'` —
uses `sed -n …p`, which only prints lines that matched and therefore drops the
ERROR line without a second filter. That reshape was needed regardless: plain
`s5cmd ls` prints `date size basename` **relative to the prefix**, so
`--show-fullpath` is what makes it emit keys. Its output is byte-identical to
what `aws s3api list-objects-v2 --query 'Contents[].Key' --output text` produced,
compared directly on the live cluster. Note also that an empty prefix exits **1**
with `no object found`, so those call sites keep an explicit `|| true` under
`set -euo pipefail`.

`presign` translates as `presign --expire 1h` (aws: `--expires-in 3600`);
s5cmd's default is 3h.

**Rehearsal 2 confirmed all three states on the live cluster**, running both branches
of `lab/03-data/verify.sh`'s `s3ls` by hand: a missing bucket gives `rc = 1` with
`ERROR "ls s3://…": NoSuchBucket … status code: 404` **on kubectl's stdout**, which the
`^ERROR ` filter empties; an existing empty bucket gives `rc = 0` and empty stdout; a
populated one lists keys. The pre-solve run correctly said *"bucket app-assets not
found"* — the true answer, not the false pass a naive port would have produced. The
`mb`-on-existing-bucket and `ls`-on-empty-bucket behaviours above were re-confirmed at
the same time.

**Residue worth knowing, none of it blocking:**

- s5cmd lives on **Docker Hub** (`peakcom` org; there is no GHCR mirror — a
  `ghcr.io/peak/s5cmd` pull is DENIED). At the venue that is irrelevant, because
  `docker.io` is in the mirror map and `cloudbox-init.sh` pre-pulls it. On a
  CI runner it is one more anonymous Docker Hub pull, on shared GitHub IPs.
- The `command -v aws` fast paths became `command -v s5cmd`, which flips which
  branch CI takes: `ubuntu-latest` ships the AWS CLI, so the *local* branch used
  to run there and the in-cluster pod branch now does. That is the branch
  attendees take, so it is better coverage — but it is slower (one pod per call,
  and module 09's `solve.sh` polls in a loop), and it was not the branch CI
  exercised before. **Rehearsal 2 priced it:** module 03 solve 1:03 → 2:33, module 04
  0:51 → 2:00, module 09 0:51 → 2:48 (**~+1:45**, the poll loop spawning a pod per
  poll). Irrelevant against 35-minute module budgets; it makes `bootstrap-test.yaml`'s
  module 09 job roughly **2.5× longer**, which is the thing to watch — in CI, not here.
- **The PodSecurity warning wall is louder now, and permanent.** Every helper pod
  (`solve-s3`, `verify-s3`, module 05's fault workloads) emits the four-line
  `restricted:latest` warning — `allowPrivilegeEscalation`, `capabilities.drop`,
  `runAsNonRoot`, `seccompProfile` — on each `kubectl run`/`apply`, and now that
  nobody has `s5cmd` locally the pod branch always runs. Cosmetic, guaranteed to be
  asked about in a room of 80, and the noisiest thing in a solve log.
- **s5cmd was deliberately not added to `mise.toml`.** It would make the "run it
  on your laptop" variant work for everybody, but it would put the version in a
  second place with nothing comparing the two (`check-consistency.sh` only knows
  the pairs it is told about). If someone wants it, add the pin *and* the
  assertion, in its own PR.

## Minor — `check-upstream.sh` prerelease-word gap

The semver comparison treats an unknown suffix as a build *flavor*
(`-rootless`, `-alpine`), which is correct and cannot under-report drift — this
was tested across all 49 suffix/version combinations the repo uses. But a suffix
that is *semantically* a prerelease and not in the known word list
(`-m1`, `-milestone2`, `-devel`, `-eap`) would be read as release-grade and
could under-report. **No pin here uses one.** Fix the word list if one ever
appears; do not "fix" the flavor-stripping.

## RESOLVED — an unreadable `~/.cloudbox/substrate` read as "no cluster was ever created"

`substrate_current()` had two outcomes and needed three. An **absent** record and
a record that exists but **cannot be used** — mode 000, owned by root after a
`sudo` mishap, or holding junk — both came back as the empty string, and every
caller wrote `s="$(substrate_current || true)"`, which threw away the status
that told them apart. Everything downstream then acted on the most dangerous
possible reading of "nothing here": `require_identity_match()` waved every
transition through, `destroy-cluster.sh` assumed docker and tore down whatever
it found, and `substrate_persist()` `mv`-ed a new value over the file nobody
could read — destroying the only record of what this machine actually built.

**Now:** `substrate_current()` returns rc 2 (with a warning on stderr) for a
record that exists and cannot be used, and rc 0 with an empty answer only when
there is genuinely none. `assert_identity_readable()` turns rc 2 into a refusal
with the hand-fix, and it is called by every **mutating** path — create,
destroy, `--refresh-endpoint`, the lifeboat's create and `--delete`,
`install.sh --write-hosts`/`--add-hosts` — plus `substrate_persist()` itself as
a backstop. It runs BEFORE `substrate_resolve_into()`, so a machine that is
going to be refused does not first spend seconds in `tbx doctor`.

**Read-only paths deliberately do not refuse.** `install.sh --check` and the labs
hear the warning and carry on: a preflight that will not run is worse than one
that says what it could not read.

## TRAP — the `/etc/hosts` block is not proof of a kind lifeboat

`kind-fallback.sh --delete` accepts `CLOUDBOX_SUBSTRATE=kind` on a machine with
no identity record — the documented lost-state recipe — but only against proof.
The marked CloudBox block used to count as proof, and it is not: **the docker
substrate writes an identical block**. On a machine whose Talos-in-Docker cluster
is up and whose record was deleted, `CLOUDBOX_SUBSTRATE=kind … --delete` then
removed a live cluster's hostnames on the say-so of an environment variable.

Proof is now kind-specific and nothing else: `kind get clusters` listing the
cluster, or containers labelled `io.x-k8s.kind.cluster=<name>`. Accepted proof is
written straight back into `~/.cloudbox/substrate`, so the retry after a declined
sudo needs no override — the proof it would have needed is the thing the first
run deleted.

Two related rules the same teardown now follows: it asks **Docker**, not `kind`,
whether the cluster is gone (so it works on a machine where kind was uninstalled,
and catches a `kind delete cluster` that exits 0 having removed nothing), and it
**exits non-zero** whenever the cluster or the block is still there.

## RESOLVED — the mirror was filled for a substrate the machine was not going to use

`mirror_target_substrate()` keyed on the presence of the `tbx` **binary**, on the
bet that a machine with tbx installed is heading towards tbx even while `tbx
doctor` fails at home — so the mirror was filled for the VMs' architecture and
the Talos disk image was warmed. The bet loses in the ordinary shape: doctor
fails, `create-cluster.sh` **builds on docker**, and the nodes are containers on a
Docker daemon that may be a whole architecture away (an amd64 Colima VM on an
Apple Silicon Mac). Worse, the mirror was *graded* by the same rule it was
*filled* by, so `install.sh --check` passed a machine whose every mirrored image
was wrong for the cluster it was about to create.

**Now:** filling (`cloudbox-init.sh`) and grading (`install.sh --check`) both
follow `substrate_resolve()` — the same decision `create-cluster.sh` dispatches
on — so the architecture is right by construction rather than by a prediction.
The cost is named where it lands: on a machine that resolves to docker only
because `tbx doctor` is failing, `cloudbox-init.sh` says so and prints
`CLOUDBOX_SUBSTRATE=tbx ./scripts/cloudbox-init.sh` for anyone who intends to fix
tbx before the venue.

`install.sh --check` also stopped taking the cached Talos disk on trust: it asks
`tbx cache list -o json` (upstream `cmd/tbx/main.go`, `usage: tbx cache list [-o
json] [<image-ref>]`) for an entry matching **this** `TALOS_VERSION` **and** the
host CPU's architecture and not marked `incomplete`, falling back to the
`~/.talosbox/cache/<schematic>/<version>/<arch>/disk.raw` layout when tbxd cannot
be reached — and saying which source answered. The old check globbed the version
directory alone, so an amd64 disk on an arm64 host read as cached.

## RESOLVED — the tbx preflight never looked at the Docker daemon for a Talos cluster

`substrate/tbx.sh`'s preflight refused over kind's containers but never over
Talos's own (`label=talos.cluster.name=<name>`). The migration case is the one
that mattered: a machine created on the docker substrate before the identity
record existed has a running cluster, an `/etc/hosts` block and a kubeconfig
context, and `create-cluster.sh` on tbx built a **second** cloudbox beside it.
Both labels are now scanned.

When Docker is installed but not running, that scan cannot be made. The preflight
then dies — unless nothing on this machine says a CloudBox cluster was ever built
here (`cloudbox_local_evidence()`: no `~/.cloudbox/substrate`, no
`~/.cloudbox/api-endpoint`, no `~/.talos/clusters/<name>`), in which case it warns
and continues. tbx needs a running Docker daemon in any case: the image mirror
its VMs pull from is a Docker container.

## TRAP — `destroy-cluster.sh` forgets which substrate this machine was on

It removes `~/.cloudbox/substrate` along with the cluster, which is right — the
record describes a cluster that no longer exists. The consequence is easy to
miss: the next bare `./scripts/create-cluster.sh` **decides again** rather than
rebuilding what was there, so an attendee who deliberately ran on docker can be
put back on tbx the moment detection likes it, with a mirror filled for the other
architecture. The destroy now names the substrate it forgot and the
`CLOUDBOX_SUBSTRATE=<it> ./scripts/create-cluster.sh` that keeps it, and
`catch-up.sh --rebuild` captures the record before the destroy and passes it to
the create.

## TRAP — Ingress health on a substrate with no load-balancer address

ArgoCD's built-in health check for `networking.k8s.io/Ingress` (gitops-engine
`pkg/health/health_ingress.go`) holds an Ingress **Progressing** until
`.status.loadBalancer.ingress` is non-empty. That is a sound rule when the
ingress controller sits behind a LoadBalancer Service. On the docker substrate
it is not: the shared Cilium ingress Service is a **NodePort** published on host
port 80, so nothing ever writes an address back and the status stays empty
forever.

The hostname scheme gave nine components a `gitops/components/<x>/ingress.yaml`,
so nine ArgoCD Applications inherited that never-finishing Progressing. The
first live CI run of the branch (run 32945328784) failed exactly there: module
03's `solve.sh` timed out after 420 s on `rustfs` (`last: Synced Progressing`)
with every rustfs workload Running, and the recovery job then reported
`argo-workflows` still `missing` after 10 minutes — the app-of-apps waves behind
the stuck app had never started. Modules 01 and 02 passed, because Gitea's and
ArgoCD's own ingresses are applied imperatively by `bootstrap-gitops.sh` and no
Application grades them.

**This reproduces on docker only.** On tbx the ingress VIP populates
`.status.loadBalancer.ingress`, so the same manifests go Healthy in seconds —
which is why a tbx rehearsal is not evidence that the docker path works.

The fix is a third Lua health customization in the `argocd-cm` patch
(`scripts/bootstrap-gitops.sh`): an Ingress on **our** class
(`ingressClassName: cilium`) is Healthy by definition, because reachability here
is proven by the labs' own curl-the-hostname verifies rather than by a field the
substrate cannot fill in. Every other class keeps upstream's rule verbatim, so a
future LoadBalancer-fronted ingress is still graded honestly. Check 15 in
`check-consistency.sh` guards both the key and the class test — deleting the
override looks harmless on tbx and breaks module 03 on every laptop in the room.

Retired by: a green `bootstrap-test.yaml` on the docker substrate (modules 01–09
plus the recovery job) **and** step 6 of the tbx rehearsal, proving the override
did not make a genuinely broken ingress read Healthy on the substrate that can
tell the difference.

## TRAP — the module 09 upload can beat the trigger's subscription

Knative Eventing's InMemoryChannel is **at-most-once**. A CloudEvent that
`broker-ingress` accepts before the Trigger's `Subscription` has been picked up
by `imc-dispatcher` is acknowledged and then dropped: no redelivery, no error,
no log line anywhere the attendee will look. The gallery simply stays empty.

CI run 32951023324 lost one exactly this way on the docker substrate: the
Subscription for `trigger/resize-on-upload` was created at 09:18:48.9, the
portal's upload landed at 09:18:49.7 (HTTP 200, no error flash — the
portal→uploader hop was fine), and the resizer never scaled from zero. By
diagnostics time the Trigger read `Ready=True` with the right subscriber, so
everything looked correct after the fact.

`Trigger` going Ready is **not** the condition to wait on: it precedes the
channel subscription being wired into the dispatcher. `lab/09-capstone/solve.sh`
now waits for `broker/default` `IngressReady`/`FilterReady`/`TriggerChannelReady`
and for the Trigger-owned Subscription to be Ready — and then, because the
dispatcher's own view still lags the API server by a short unbounded moment,
**retries the upload**: three attempts, 60 s of thumbnail-polling each. This
mirrors what an attendee does in the browser when nothing appears — upload
again — so the lab text needs no new step.

The race pre-exists on `main` (same single-upload / 240 s-wait shape); this
branch is where it was first observed, not where it was introduced. The
diagnostics collector could not explain it either: the `-l app` namespace loop
in `bootstrap-test.yaml` misses `mt-broker-ingress`, `mt-broker-filter` and
`imc-dispatcher`, whose pods label with `eventing.knative.dev/brokerRole` and
`app.kubernetes.io/component` rather than `app`, so only the three controllers
were ever captured. They are now collected by deployment name, along with the
namespace's broker/trigger/subscription/channel YAML.

Retired by: a `bootstrap-test.yaml` run whose module 09 reports the thumbnail on
attempt 1 — and, if one ever reports attempt 2 or 3, by the newly collected
`broker-ingress`/`imc-dispatcher` logs saying what happened to the first event.
