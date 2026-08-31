# Rehearsal 11: first full agent run on docker, PR #222 content (2026-08-30, 00:49–01:41)

Minutes after rehearsal 10's panic took tbx off the host, the same night's
testing continued on the docker substrate: a participant agent run over the
unmerged going-deeper lab content (PR #222, `labs/going-deeper-tasks` at
`f08dc09`, read-only worktree `/tmp/cbx-tasks`), modules 00–09 for real, no
`catch-up.sh` anywhere. Its record is `~/workshop-run-report.md`, written
append-only during the run; the fixes it forced are commit `c9325f9`.

## Setup

- Substrate: docker (Talos-in-Docker), reached by fallback, tbx uninstalled
  after the panics. Docker 29.5.2, 4 CPU / ~12 GiB VM, on the 128 GB host.
- Mirror: warm (9.1 GB in the docker-side registry, separate from the tbx
  cache rehearsals 8–10 used).
- Dispatched 00:49 local; the report's last write is 01:41.

## Results

| | rehearsal 11 (docker) |
|---|---|
| modules | 00–09 all done for real; every `verify.sh` literally run |
| `verify.sh` exit 0 | 01, 04, 05, 06, 08, 09 |
| `verify.sh` exit 1 | 00 (hosts/sudo, environment-side), 02, 03, 07; every FAIL independently re-verified as a false negative from the sandbox's curl-only DNS failures |
| `create-cluster.sh --skip-cilium` | **1:30** wall; Cilium apply < 1 s, nodes Ready ~1 min after the pods started |
| interventions | 2, both substrate identity (below), none in cluster creation itself |
| memory | no OOMKills or evictions; worker peak 4.65 GiB / 6 GiB (77.4%), control plane 2.90 / 4 (72.6%), ~60 pods, 21 apps, 3 live Postgres clusters |

## What it found

- **Module 08's storage trap, the run's biggest find.** The going-deeper
  resize `small` → `medium` silently stalls forever: `local-path` has no
  volume expansion, CNPG's reconciler retries every ~24 s on "only dynamically
  provisioned pvc can be resized…", the Cluster update never completes, and
  **`status.phase` reads "Cluster in healthy state" the entire time**. The
  documented shrink-back refusal does reproduce, but off the webhook's 5Gi
  high-water memory, not off a medium state that ever finished composing. The
  task was rewritten to teach exactly this (`c9325f9`).
- **Adventure 3's default-deny enforced nothing.** The briefing's
  `ingress: []` / `egress: []` is an empty list of rules, not a rule matching
  nothing; Cilium 1.20 enforces nothing for it. Proven behaviourally, with
  `egress: []` a pod still resolving DNS and `egress: [{}]` blocked,
  and the briefing corrected.
- **The curl verify failures.** All the exit-1s traced to name resolution
  failing for curl (and only curl; `crane`'s Go resolver never blinked),
  intermittently. Root-caused after the run as a 5.004 s AAAA stall against
  `--max-time 5`; every lab `verify.sh` curl now passes `-4`, because three
  modules were failing with messages blaming the attendee for work that had
  succeeded. Also flagged: lab 06's verify had a Host-header fallback that
  labs 02/03 lacked, so the same hiccup read as real FAIL or non-issue
  depending on the module.
- **Stale substrate persistence.** `~/.cloudbox/substrate` still said `tbx`
  and is trusted over fresh detection, so `cloudbox-init.sh` set off down the
  tbx path, on a machine tbx had just been removed from, until a human
  intervened.
- The other two going-deeper tasks held: module 04's Postgres 17→18 in-place
  major upgrade worked first try (~90 s, real `pg_upgrade` logs), and module
  07's rebuild-`:v1`-and-watch-nothing-happen reproduced exactly as written.

## Verdict carried forward

The platform is mechanically sound end to end on docker at the published
resource floor, and two of its status reports lie: CNPG's `status.phase`
during a stuck resize, and a persisted substrate identity nothing
re-validates. Rehearsal 12 ran the rewritten content on merged main to hold
the fixes to their own words.
