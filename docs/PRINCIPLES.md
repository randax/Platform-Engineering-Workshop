# Workshop Design Principles

The rules we hold ourselves to while building this workshop. Grounded in
[docs/RESEARCH.md](RESEARCH.md); when a lab or script violates one of these, fix the lab.

## The message

1. **Local is the message.** "Cloud on your terms" demonstrated on hardware the attendee
   owns *is* the point. The platform must survive on their laptop after the conference —
   that running artifact is the one thing an AI assistant or a video can't give them.
2. **Nothing requires the internet at runtime.** All images pre-pulled from GHCR with
   pinned tags; git server (Gitea) runs in-cluster; ArgoCD never points at GitHub.
   Conference WiFi carries keystrokes, not gigabytes.
3. **Every lab ends in a visible win** — a URL, a psql prompt, a synced app, a green check.
   Four hours of `kubectl apply` with nothing to show is an install-fest, not a workshop.

## Teaching in the AI era

4. **State outcomes, not steps.** Every module is "make your cluster reach state X",
   checked by a script — not "run these 12 commands." If an AI can one-shot a lab from its
   instructions, the instructions were the problem. AI assistants are explicitly welcome;
   say so in the opening slides.
5. **Broken-on-purpose is the default texture.** Diagnosing an injected fault on a live,
   slightly-weird system teaches more per minute than installing ever does — and it's where
   both humans and their AI assistants must engage with reality instead of with text.
6. **Verify against the running system, never against text.** Each task ships a
   `verify.sh` with the exit-0 contract and `FAIL:`-prefixed actionable messages; many
   small checks beat one big one. Every check is CI-tested with its matching `solve.sh`
   (check fails → solve → check passes) so the checks themselves can't rot.
7. **Hints are layered, free, and collapsible.** Per task: goal → guiding question →
   concrete hint → full solution in a collapsed `<details>` block (eficode-katas style).
   The room self-sorts by how many layers they open. No hint penalties — they backfire.
8. **Checkpoint understanding, not completion.** Two-minute explain-backs at module
   boundaries ("tell your neighbor why the fix worked"). AI-generated fixes are fine;
   un-understood fixes aren't done.
9. **Meet the moment head-on**: one segment where attendees point an AI agent at their own
   cluster to diagnose a fault — then verify or falsify its answer against live state.
   Include one fault where the obvious AI diagnosis is plausible but wrong. Teaching
   *verification of agent output* is the 2026 skill.

## Surviving the room

10. **Plan half of what fits.** ~5 exercises planned, 3 expected to finish; core path vs.
    stretch labs decided on paper before any dry-run; bonus challenges for the fast 20%.
    Hands on keyboards within the first 10 minutes.
11. **Catch-up is scripted state, not hope.** Per module: force-push the canonical state to
    the in-cluster Gitea and let ArgoCD converge; plus a nuke-and-rebuild-to-checkpoint
    script for genuinely broken clusters. `git tag` per module; `solutions/` directory;
    everything public so stragglers finish at home.
12. **Publish honest specs and gate on a pre-flight check.** 16 GB RAM minimum
    (≥10 GB to Docker), 32 GB recommended; `install.sh --check` verifies everything and
    says so plainly. A supported-platform matrix (macOS/Linux fully; Windows via WSL2
    best-effort — pair up if it fails) beats silent Windows suffering.
13. **The room is for humans, not content delivery.** 1 helper per ~8–10 attendees on top
    of 2 instructors; sticky-note help signals; walk the solution on screen to re-sync;
    protect the last 30 minutes for open-ended tinkering and weird questions. Slides exist
    to frame labs, never to compete with them.
14. **Pin everything, rehearse the unknowns.** Exact versions in mise.toml, scripts, and
    manifests; weekly CI bootstrap so drift breaks our build, not the workshop. The two
    combos nobody has published (BuildKit-on-Talos, Knative-on-Talos+Cilium) get rehearsed
    first, not trusted.
15. **Be accurate about the ecosystem.** This audience fact-checks. MinIO wasn't
    "relicensed" — its open-source edition was discontinued; RustFS is an independent
    reimplementation, not a successor. Say it right in README and slides.
