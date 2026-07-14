# Helper cheat-sheet — Cloud on Your Terms (JavaZone 2026)

You're roaming a room of ~30–80 people building a Kubernetes platform on their
laptops. This is the field guide: how the day flows, how attendees signal for
help, and — the useful part — the failures we've actually seen and their fixes.

Target ratio: **1 helper per 8–10 attendees**, plus the two speakers. If the
room is bigger than your helper count can cover, pair attendees up early.

## How help works

Two-color sticky notes on the laptop lid:
- **Green up** = "I'm fine / done with this module."
- **Red up** = "I'm stuck — come find me." (No hand-raising; you scan the room.)

When you reach a red note: **don't take the keyboard first.** Ask "what did the
last command say?" — the labs are built so the error text usually names the
problem. Reading it together is the lesson.

## The shape of the day

Core path everyone should finish: **modules 00–05**. Stretch (fast folks / take-home): **06–09**.

| # | Module | The "done" signal |
|---|--------|-------------------|
| 00 | Setup / preflight | `./scripts/install.sh --check` all green |
| 01 | Talos + Cilium | 2 nodes Ready, no kube-proxy pods |
| 02 | GitOps (Gitea + ArgoCD) | edit → push → ArgoCD converges |
| 03 | CNPG Postgres + RustFS | psql works; a presigned S3 URL opens |
| 04 | Crossplane self-service | one YAML claim → a whole database appears |
| 05 | Debug with AI | the four seeded faults found and fixed |
| 06–09 | Knative · CI · portal · capstone | stretch — see the lab READMEs |

**The universal escape hatch:** `./scripts/catch-up.sh <module>` force-pushes the
canonical end-state of module N to the attendee's in-cluster Gitea and lets
ArgoCD converge. If someone is hopelessly behind or their platform is a mess,
this is faster than debugging. `./scripts/catch-up.sh <module> --rebuild` nukes
and recreates the cluster from scratch (~10 min with pre-pulled images) — the
last resort.

Every module also has `./verify.sh` (checks the outcome) and, in its README,
layered hints ending in a full solution. Point stuck attendees at their own
`lab/NN-*/README.md` hints before you spoil it.

## Failures we've actually seen (and the fix)

These are real — most were found by running the whole thing on clean machines.

**Setup / prework (module 00)**
- *`install.sh --check` fails on the image mirror* → they didn't run
  `./scripts/cloudbox-init.sh` at home, or it didn't finish. If they have
  internet, the cluster still comes up (nodes pull upstream); it's just slower.
  At a hostile-wifi venue, pair them with a neighbor whose mirror is populated.
- *A tool "not found" right after `dev-setup.sh`* → mise isn't on PATH yet.
  **Restart the shell** (mise activation), or the message says so.
- *Windows attendee stuck* → they must be inside **WSL2** with Docker Desktop's
  WSL2 backend, running the Linux tools. If it's fighting them, pair up — don't
  burn 20 minutes on it.

**Cluster (module 01)**
- *Nodes stay NotReady* → Cilium is still rolling out; give it a minute. If it
  persists, `kubectl -n kube-system get pods` — a Cilium agent in CrashLoop
  usually means Docker doesn't have enough memory (needs ~10 GB allocatable).
- *`talosctl` complains about "nodes not set"* → they're on an old checkout;
  `git pull`. (Fixed in the current scripts.)

**GitOps (module 02)**
- *ArgoCD shows an app "OutOfSync" forever but everything's green* → almost
  always a genuine drift; check `argocd app diff`. (The classic no-op-field
  version of this is fixed in our manifests.)
- *Gitea push rejected "shallow update not allowed"* → they cloned with
  `--depth`; `git fetch --unshallow` then re-run `seed-gitea.sh`.

**Data / self-service (03–04)**
- *A PVC hangs Pending* → the storage provisioner. `kubectl -n
  local-path-storage get pods` should show it Running. (The PSA-label fix is in
  the current manifests; an old checkout is the usual culprit.)
- *Crossplane XR never goes Ready* → `kubectl -n demo describe workshopdatabase
  <name>` and read the events; it usually names the composed resource that's
  unhappy (a bad size, a missing CRD).

**Debug module (05)** — this one is *supposed* to break.
- The four faults are deliberate. If an attendee thinks they're broken "for
  real," that's the module working. Each fault's `description.md` is the full
  spoiler if they're truly stuck. Fault 04 is the "AI gets it wrong" trap — the
  obvious answer (port/probe/policy) is wrong; the smoking gun is `kubectl get
  endpoints`. Let them sit with it; that's the lesson.

**Anything, anywhere**
- *One weird broken thing, no time to debug* → `catch-up.sh <their module>`.
- *Cluster wedged* → `catch-up.sh <module> --rebuild`.
- *Docker Hub rate-limit errors mid-run* → the room shares one venue IP.
  Everything should come from the local mirror; if something's pulling from
  docker.io live, it's an image we missed pre-pulling — flag it to the speakers.

## What to tell people about AI

AI assistants are **welcome** — say so cheerfully. The goal is the running
platform and understanding it, not the typing. If someone's agent finishes a
lab in 30 seconds, ask them the explain-back question from the module ("why did
that work? what would you check in prod?"). Module 05 is designed to make the
agent-and-human verify against the live cluster.

## Quick reference

```
./scripts/install.sh --check          # is this laptop ready?
./scripts/create-cluster.sh           # module 01
./scripts/bootstrap-gitops.sh         # module 02
./scripts/seed-gitea.sh               # module 02
./scripts/catch-up.sh <N>             # jump to end of module N
./scripts/catch-up.sh <N> --rebuild   # nuke + rebuild to module N
./lab/NN-*/verify.sh                  # did this module's outcome happen?
kubectl get pods -A                   # the first thing to look at, always
```
