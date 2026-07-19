# Module 10 — canonical state

This is the day-2 operations and kagent checkpoint. Catch-up lands the kagent
Application in `gitops/apps/` for ArgoCD to install and resets
`gitops/components/demo/demo-web.yaml` to the clean baseline, reverting any injected
bad-release scenario.

`catch-up.sh` does **not** create any attendee-side secret or touch host-side Ollama
state. Kagent's ModelConfig expects Ollama on the attendee's own machine at
`host.docker.internal:11434`; that host service is outside catch-up's scope, just as it
is outside the module's `inject.sh` scope.

**Catch-up is cumulative; the lab is not.** The lab's scenario path needs only
module 02, but `catch-up.sh` force-push *replaces* `gitops/apps/` with this tree —
so like every solutions tree it must carry everything earlier modules may have
enabled, or catching up would prune capabilities out from under an attendee who
had them running. That is why `post.sh` chains module-09's (and thereby
module-07's) idempotent post-steps: the cumulative tree enables `hello-site`,
whose `localhost:30500` image exists only after the in-cluster build, and the
ArgoCD convergence gate would otherwise never go green. Expect `catch-up.sh 10`
on a fresh cluster to take as long as catching up to module 09 plus the kagent
install — it provisions the whole platform, not just this module's slice.

To reset only the module's demo-web scenario without a full catch-up, run:

```bash
lab/10-day2-ops/restore.sh clean
```
