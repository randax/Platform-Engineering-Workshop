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

## Zones, patrol, and the question backlog

These three mechanics are borrowed from Carpentries practice (see Wilson,
*Ten Quick Tips for Delivering Programming Lessons*) — they're what makes
1 helper per 8–10 people actually work:

- **You own a zone.** Before the workshop starts, each helper takes a fixed
  block of ~6–8 seats and keeps it all day. Nobody outside a zone means nobody
  is unwatched; you'll also learn your people's pace, which makes stuck-ness
  visible earlier.
- **Patrol, don't perch.** Circulate continuously through your zone watching
  *screens*, not stickies — a red sticky is a request, but a terminal that
  hasn't changed in five minutes is a fact. Intervene early; waiting for the
  sticky means catching people after the frustration, not before it.
- **Count greens at each checkpoint.** When the lead calls a mid-lab
  checkpoint ("hands up if verify passes"), report your zone's green count —
  that's how the walk-the-solution timing gets decided from data instead of
  front-of-room vibes.
- **Feed the question backlog.** The second time you answer the same question,
  write it on a sticky and put it on the front wall. The lead triages the wall
  aloud at every walk-the-solution — your 1:1 answer becomes whole-room
  teaching, and you stop answering it a third time.

## The adventure hour: door ownership

Each `adventures/` door has a **named owner** (assigned before the workshop,
written on the front wall during the pitch). If you own a door: read your
briefing's *Known traps* section in advance — it was written as your
cheat-sheet — and treat the warm-up as sacred: it's the ~15-minute visible win
that guarantees nobody hits the closing hard-stop empty-handed. Helpers without
a door float across zones as usual. When the hard-stop signal comes (10 minutes
before the end), help the room actually stop — the close is part of the
workshop, not an optional outro.

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
  **Restart the shell** (mise activation), or the message says so. `dev-setup.sh`
  now *offers* to add the activation line to their shell rc — if they said no,
  say yes this time, or have them use `mise exec -- <tool>` for everything.
- *Windows attendee stuck* → they must be inside **WSL2** with Docker Desktop's
  WSL2 backend, running the Linux tools. If it's fighting them, pair up — don't
  burn 20 minutes on it.

**Which kubeconfig am I even looking at? — read this before you diagnose anything**

`mise.toml` pins `KUBECONFIG` to **`~/.kube/cloudbox.conf`** for this repo, so the
workshop cluster lives in a file of its own and never lands next to the dozen
contexts a consultant arrives with. (A rehearsal found `lab/01-cluster/verify.sh`
grading a real 36-node corporate cluster after a `destroy-cluster.sh`, because
`kubectl` fell through to the next entry in `~/.kube/config`. The scripts refuse to
run against a non-workshop context now, and this is the other half of that fix.)

**The pin only reaches people through mise.** Three states, and you must know which
one you are standing in front of:

| | scripts | their bare `kubectl` | verdict |
|---|---|---|---|
| mise activated in their shell | `~/.kube/cloudbox.conf` | same | fine |
| mise not involved at all | `~/.kube/config` | same | fine — this is how the workshop always worked |
| **`mise run` / `mise exec` + a `kubectl` they installed themselves** | `~/.kube/cloudbox.conf` | `~/.kube/config` | **broken — the cluster is real, their terminal is looking in the wrong file** |

First question when someone's cluster "disappeared", or `kubectl get nodes` shows a
cluster that is obviously not theirs:

```bash
./scripts/install.sh --check      # names the file in effect, and fails on the third state
echo "$KUBECONFIG"                # empty = the pin is not in this shell
kubectl config get-contexts       # admin@cloudbox present?
```

If the cluster is in `~/.kube/cloudbox.conf` and their shell isn't reading it, the
context guard says so in as many words and tells them **not** to rebuild. The fix is
one line — **do not let them run `catch-up.sh --rebuild`, that is 10 minutes for
nothing**:

```bash
export KUBECONFIG=~/.kube/cloudbox.conf      # this terminal, right now
eval "$(mise activate bash)"                 # every terminal from now on
```

Two smaller consequences worth knowing: a terminal **outside the repo directory**
does not get the pin either (mise env is per-directory), so `cd` back into the repo
before debugging; and their own clusters are untouched — `~/.kube/config` is not
modified except that `destroy-cluster.sh` cleans this workshop's own entries out of
it, by name.

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

echo "$KUBECONFIG"                    # empty = mise's pin is not in this shell
export KUBECONFIG=~/.kube/cloudbox.conf   # "my cluster vanished" — try this BEFORE rebuilding
```
