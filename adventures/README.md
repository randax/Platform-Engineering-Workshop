# Adventures — the last hour is yours

The core path (modules 00–06 and 09) ends with a platform that works: a cluster you own,
GitOps as the only write path, databases and buckets as a service, self-service
via Crossplane, and the confidence of having debugged it. What happens next is
not one path — it's five doors. Pick the one that matches why you came.

**These are briefings, not labs.** There is no `verify.sh`, no `solve.sh`, and no
single right answer — that's deliberate (see the carve-out in
[docs/PRINCIPLES.md](../docs/PRINCIPLES.md)). Each briefing gives you a mission,
a warm-up with a guaranteed win, an escalating build, and the traps we know
about. Where you take it is yours. **Scope honestly: start here, finish at
home** — the platform runs offline on your laptop, which is the point of the
whole day.

## The doors

| Door | You came for… | Briefing |
|---|---|---|
| 0 · The marked trail | guidance, a curated finale | this page, below |
| 1 · App dev | building applications on a platform | [1-app-dev.md](1-app-dev.md) |
| 2 · Platform | extending the platform itself | [2-platform.md](2-platform.md) |
| 3 · Security | locking it down, proving it | [3-security.md](3-security.md) |
| 4 · Infra | Talos, Cilium, the metal layer | [4-infra.md](4-infra.md) |

## Getting to a door's starting state

Every briefing names its prerequisites as module numbers. You don't need to have
done them — `./scripts/catch-up.sh <module>` force-pushes the canonical end
state of that module to your Gitea and lets ArgoCD converge. Jumping straight
from module 05 to any door is a supported move, not a cheat.

```bash
./scripts/catch-up.sh 7    # e.g. everything through module 07, ~2 minutes
```

## Door 0 — the marked trail

Modules 07, 08 and 10, the three the guided day does not reach. 06 and 09 are core now.
Rehearsed, hinted, each with a `verify.sh` and a visible win:

- **[Module 07 — CI on your terms](../lab/07-ci/)**: your cluster builds its own
  images — Gitea → BuildKit → Zot, no external service touched.
- **[Module 08 — The Console](../lab/08-portal/)**: a real cloud console whose
  entire source you can read; create a database from a form.
- **[Module 10 — Day-2 ops](../lab/10-day2-ops/)**: an in-cluster AI agent
  diagnoses live faults; you fact-check it.

Fast finishers: walk the trail, then come back and pick a door — the doors
assume nothing beyond module 05, but they get richer with each module you have.

## For helpers

Each briefing's **Known traps** section is your cheat-sheet for that door. The
supportable answer to "is this possible?" is usually "yes, and here's the trap
you're about to hit" — not "here's the solution". Open-endedness is the design.
