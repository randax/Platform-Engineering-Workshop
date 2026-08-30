# Rehearsal 5 — the substrate split (planned)

Rehearsals 1–4 all ran Talos-in-Docker. The substrate split adds a second machine
substrate — real Talos VMs via [talos-box](https://github.com/randax/talos-box) —
and **not one line of that path has been run end to end.** Everything below is
therefore a checklist, not a result. Timings are blank on purpose: the owner
fills them in on the day, the way the four numbers in the venue table in
`docs/REHEARSALS.md` were filled in.

`tbx system install` (it sudo-s itself; upstream's README says never a PATH-dependent
`sudo tbx …`) is a **one-time privileged prerequisite** — it installs
the helper that does the VM and network wiring. It is not part of any script and
nobody should discover it at the venue.

Each step names the `docs/HAZARDS.md` entry it retires, so a green run can be
turned into edits there rather than into a feeling.

| # | Step | Time | Result |
|---|------|------|--------|
| 0 | portal release + re-mirror (below) | | |
| 1 | `tbx system install` / `tbx doctor` | | |
| 2 | prework: `cloudbox-init.sh`, `install.sh --check` | | |
| 3 | `create-cluster.sh` | | |
| 4 | registry mirror reaches the VMs | | |
| 5 | bootstrap + seed, ingress on the hostname | | |
| 6 | labs 01–06 | | |
| 7 | module 07 (registry + in-cluster build) | | |
| 8 | modules 08/09 (Console, picture pipeline) | | |
| 9 | module 10 (kagent + Ollama) | | |
| 10 | destroy → create → `catch-up --rebuild 07` | | |
| 11 | full-tunnel VPN | | |
| 12 | offline | | |
| 13 | docker path on the same Mac | | |
| 14 | `bootstrap-test.yaml` | | |

**0. Publish the portal image first.** Merge the branch, let `release-please` open
its release PR (it rewrites every pinned ref — pins are never hand-edited), merge
that, wait for `build-images` to finish, verify every ref in `scripts/images.txt`
resolves with the `crane manifest` loop, then re-run `./scripts/cloudbox-init.sh`
to re-mirror. Until this is done the Console's function URLs are wrong on both
substrates and step 8 cannot pass.
*Retires:* TRAP — the pinned portal image predates `KNATIVE_DOMAIN`. *Guards
against:* TRAP — the release/pin publish window.

**1. Install the helper.** `tbx system install && tbx doctor` → **exit 0, no FAIL**
(checks that need a cluster — `routes`, `system-dns`, `inter-cluster`, `talos-services` —
`SKIP` until one exists; a WARN never fails doctor).

**2. Prework.** `./scripts/cloudbox-init.sh` → ends with `talos-disk=yes ·
tbx-doctor=pass`. Confirm the disk image is really there, not just its directory:

    find ~/.talosbox/cache -path '*v1.13.8/*disk.raw'

must be non-empty. Then `./scripts/install.sh --check` → exit 0. Note whether the
Ollama bind warning fired.
*Retires:* the offline half of LIVE — Ollama binds to loopback (the warning path),
and confirms the disk-cache assertion added after an interrupted `tbx cache pull`
left a directory behind.

**3. Create the cluster.** `time ./scripts/create-cluster.sh`. Expect: the subnet
line; both nodes in maintenance within **≤300 s**; `Ingress VIP: 172.30.<n>.200`;
and **no** ".200 is not conventional" warning. Record wall-clock — this is the
number the 240-minute budget cares about, and there is no prior measurement for it.
*Retires:* TRAP — `.200` resolves before anything owns it.

**4. The mirror actually reaches the VMs.** `talosctl -n <cp> get registries`
shows the eight explicit entries pointing at `http://172.30.<n>.1:5059` (tbx's own
mirror, issue #206 — the `:5001` crane container of rehearsals 5–6 is docker-only
now); the worker's kubelet logs show pulls from that address; `tbx cache list`
(and `tbx doctor`'s mirror-health line) show them served from `~/.talosbox/cache`.
No Docker is involved on this substrate — this is the step that proves it.

**5. Bootstrap and seed.** `./scripts/bootstrap-gitops.sh && ./scripts/seed-gitea.sh`,
then `dig +short gitea.cloudbox.k8s.test` → the `.200` VIP, and
`curl -I http://gitea.cloudbox.k8s.test` → 200. Watch the git push for Envoy 413s
or timeouts. Gitea's UI clone box shows the in-cluster URL — use the hostname.

**6. Labs 01–06.** `solve.sh` then `verify.sh` for each. Lab 06 must pass **via its
own URL**, not the fallback — and that URL is now
`http://hello-demo.kn.cloudbox.k8s.test/`, one label, from the `domain-template`
curation. Then do the thing the fixed rules exist for: create a ksvc in a namespace
nobody listed (`kubectl create ns scratch` + any ksvc) and confirm it answers on tbx
with no extra Ingress rule. On docker it will not resolve — that is expected and
documented; `curl -H "Host: …" http://localhost/` must still answer.
*Retires:* RESOLVED — a Knative Service in a namespace nobody listed had no route.

**7. Module 07.** `./scripts/catch-up.sh 07 && (cd lab/07-ci && ./verify.sh)`. The
`crane copy` goes to `zot.cloudbox.k8s.test` through the ingress; the in-cluster
build pushes and pulls `localhost:30500` from a real node. Both halves matter —
they are the two sides of the hostname/NodePort split, and the node-side half is
specifically what tbx's catch-all `"*"` mirror would have broken (see the RESOLVED
entry in `docs/HAZARDS.md`). **CI does not prove this**: `bootstrap-test.yaml` builds
the first-party images locally as `v0.1.0` while the manifests pin `v0.2.2`, so the
cluster silently falls back to GHCR and the offline first-party image path is never
exercised on any runner. This step is the only place it is.
*Retires:* the tbx half of the catch-all mirror — the one path a green CI run cannot
speak to.
*Retires:* the tbx half of the catch-up clone-URL fix — `catch-up.sh` used to
clone the platform repo from a NodePort that only exists on docker.

**8. Modules 08 and 09.** `http://portal.cloudbox.k8s.test` loads; upload a
picture; the presigned URL is `http://s3.cloudbox.k8s.test/...` **and loads** (a
`SignatureDoesNotMatch` means the Host rewrite is wrong, not the credentials);
Console app URLs read `<name>-<namespace>.kn.cloudbox.k8s.test` — which is what proves
step 0 landed.
*Retires:* TRAP — the pinned portal image predates `KNATIVE_DOMAIN`.

**9. Module 10.** `OLLAMA_HOST=0.0.0.0 ollama serve`; enable kagent; then

    kubectl -n kagent logs job/kagent-ollama-host -c render-patch     # shows 172.30.<n>.1:11434
    argocd app sync kagent
    kubectl -n kagent get modelconfig default-model-config -o jsonpath='{.spec.ollama.host}'

The last value must be **unchanged** after the sync. Record `tbx status` and the
VM's RSS at this end state — that is what the `TBX_*` memory pins should be
corrected against.
*Retires:* LIVE — Ollama binds to loopback · WATCH — three settings have to agree
for the Ollama host to survive selfHeal · WATCH — `bootstrap-gitops.sh` creates
namespace `kagent` before ArgoCD owns it · and gives LIVE — tbx VM memory is a
moving ceiling its first real number.

**10. The recovery path.** `./scripts/destroy-cluster.sh --purge-mirror &&
./scripts/create-cluster.sh`, then `./scripts/catch-up.sh --rebuild 07`. Rehearsals
2 and 4 both found blockers here and nowhere else.

**11. VPN.** With a full-tunnel VPN connected: `tbx doctor` (expect a `routes`
FAIL), `curl http://gitea.cloudbox.k8s.test`. Document exactly what the attendee
sees.
*Retires:* TRAP — a full-tunnel VPN blackholes 172.30.0.0/16.

**12. Offline.** Wi-Fi off: destroy, create and bootstrap must all succeed from the
mirror and the cached disk image. This is the hard requirement, on a substrate
that has never been asked.
*Observe, do not fix:* enable the **crossplane** Application with the WiFi still ON, and
write down that you did. `function-patch-and-transform` is fetched by Crossplane's package
manager, not through the node's registry mirror, so it is the one component that cannot
come up offline (HAZARDS — "module 04's Crossplane Function is fetched by Crossplane").
Then turn the WiFi off and confirm everything *else* — including a fresh
`catch-up.sh 04` — still converges.

**13. The docker path, same Mac.** `CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh`
→ **one** sudo prompt, and it comes **last**, after the cluster is Ready; `grep -c cloudbox
/etc/hosts`; `curl http://argocd.cloudbox.k8s.test`; any `destroy-cluster.sh` leaves
`/etc/hosts` **byte-identical** to what it was before (for a newline-terminated file — the
awk rewrite terminates its last line). Also **decline** the password once: the cluster must
finish and stay up, and `./scripts/install.sh --write-hosts` must then write the block.
Repeat under Colima if it is available on the machine.
*Retires:* TRAP — /etc/hosts needs sudo · LIVE — host port 80 is the only
privileged port the workshop binds.

**14. CI.** `gh workflow run bootstrap-test.yaml` — both jobs green.

**15. The gate.** Keep `CLOUDBOX_SUBSTRATE_DEFAULT="tbx"` **only if steps 3–12
pass**. Otherwise flip it to `docker` in `scripts/versions.env:69` by **Aug 31** and
ship tbx as the opt-in path. The decision is a date, not a judgement call, because
the alternative is discovering the answer in the room.
