# Rehearsal 13: the adventures and the recovery tooling, on purpose (2026-08-30, ~09:45–10:54)

The third agent-driven run of the day skipped the happy path entirely: no run
had ever touched the four adventure briefings or deliberately broken the
platform, so this one did nothing else. Repo `/tmp/cbx-run3` @ `bacbd4d`,
docker substrate, starting from rehearsal 12's module-09 end-state cluster.
Its record is `~/workshop-run3-report.md`; the fixes it forced are commit
`cd155aa`, and its headline result is now a LIVE entry in `docs/HAZARDS.md`.

## Setup

- Substrate: docker, same 128 GB host and colima VM as rehearsals 11–12.
- Cluster: pre-existing module-09 end state; destroyed and recreated mid-run,
  then restored with `catch-up.sh 9`.
- GitOps work went through a fresh clone of the in-cluster Gitea repo, ArgoCD
  only, no manual `kubectl apply`.

## Adventures: doors 1, 2 and 4 (door 3's Arc 1 ran in rehearsal 12)

- **Door 1**: the warm-up Application XR worked end to end, verified by
  transaction (`psql -c "select 1;"` through the generated secret, real s5cmd
  Jobs), and Level 1's event mesh held its claim: one new ksvc plus one new
  Trigger, uploader/resizer untouched. **Bug**: "you know it works when the
  URL serves" is unreachable as written on docker. `/etc/hosts` has no
  wildcard, a brand-new ksvc's hostname is never added anywhere, and the door
  never says to add it. The backend answered fine via `--resolve`.
- **Door 2**: the cert-manager tier worked cleanly: vendored, catalogued,
  Synced/Healthy with zero manual kubectl, and a real certificate decoded out
  of the resulting secret. The Kafka tier and the Topic XR apex were skipped
  for time. **Bug (cross-door)**: door 4's known-traps section quotes
  `cert-manager-controller:v1.19.1` where `scripts/images.txt` pins
  **v1.19.2**, a copy-pasteable check that finds nothing.
- **Door 4**: the warm-up's three claimed machine-config choices all verified
  against the raw config. Arc 2's etcd snapshot ran for real (36,200,480
  bytes, 2706 keys), and found an undocumented trap: `talosctl` run from
  outside the repo fails on the mise shim (`No version is set`). **Bug, found
  by reading**: Arc 3's `helm upgrade` example omits `--server-side=false`,
  which every call site in `scripts/lib.sh` passes deliberately.
- **Honesty notes.** Arc 1 (machine-config patch) is **not tested**: the
  agent's own tool sandbox refused `talosctl patch` twice, a limitation of
  the session, not a workshop result. And Arc 3's fix was verified by reading,
  not by executing; the agent chose not to risk cluster networking on the one
  shared cluster. Weaker evidence than a run; the command has still never been
  executed as corrected. Arcs 4/5 were not attempted.

All three briefing bugs fixed in `cd155aa`.

## Recovery and failure paths

| | rehearsal 13 (docker) |
|---|---|
| `catch-up.sh 07` against the live module-09 cluster | **18.6 s**; later modules' apps untouched (`prune: false` held), lab 09 verify still exit 0 |
| `catch-up.sh 07` re-run (idempotency) | **5.9 s**, "nothing to push" |
| delete a Deployment ArgoCD owns | self-healed in **~10 s** |
| scale a component to 0 | reverted in **~5 s** |
| **delete a managed namespace** | retried 5 times, then **stopped permanently**: idle **23 minutes**, `refresh=hard` did not help; a manual Sync operation recovered it in **~8 s** |
| corrupt a manifest and push | no self-heal possible; sync `Unknown`, live app untouched, `ComparisonError` names the file and line; revert recovered in one refresh cycle |
| `create-cluster.sh` (second cluster, warm mirror) | **101 s** |
| `bootstrap-gitops.sh` / `seed-gitea.sh` | **42 s** / **3 s** |
| `catch-up.sh 9` from the bare cluster | **188 s** to the full module-09 state, verify exit 0 |
| leakage between clusters | none: one kubeconfig context, one hosts block, correct substrate file, no stale ArgoCD apps |

**The headline: ArgoCD gives up in silence.** A deleted namespace exhausts the
`retry: limit: 5` every Application carries and then never tries again,
qualitatively different from every other breakage, which healed in 5–10 s
unattended. The Application's condition message is precise
(`namespaces "pipeline" not found (retried 5 times)`), but nothing in the
workshop tells an attendee that a stuck `OutOfSync` sometimes just needs the
Sync button, and there is no `argocd` CLI on the laptop to press it from the
terminal. The run's own verdict: in a room of 40, "my app has been stuck in
the dashboard for ten minutes" is the ticket most likely to get filed, and the
fix is a five-second click nothing points anyone toward. Now a LIVE entry in
`docs/HAZARDS.md`.

Two limitations of the rehearsal, not of the scripts: `destroy-cluster.sh`'s
one interactive step (`sudo tee /etc/hosts`) sat blocked forever in this
non-interactive session; the teardown around it completed, and the leftover
hosts block was byte-identical, so the recreate needed no sudo at all. And
`kind-fallback.sh` was read but **not run**: host port 80 was already bound by
the live cluster and the script overwrites `~/.cloudbox/substrate` on success,
so it genuinely cannot coexist with a live docker cluster. The lifeboat is
still unexercised, as `docs/HAZARDS.md` already records.

`install.sh --check` was confirmed genuinely read-only (identical state before
and after, no mutating calls in the script) and every verdict matched reality,
76/76 images included.
