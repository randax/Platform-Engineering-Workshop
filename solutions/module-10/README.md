# Module 10 — canonical state

This is the day-2 operations and kagent checkpoint. Catch-up lands the kagent
Application in `gitops/apps/` for ArgoCD to install and resets
`gitops/components/demo/demo-web.yaml` to the clean baseline, reverting any injected
bad-release scenario.

`catch-up.sh` does **not** create any attendee-side secret or touch host-side Ollama
state. Kagent's ModelConfig expects Ollama on the attendee's own machine at
`host.docker.internal:11434`; that host service is outside catch-up's scope, just as it
is outside the module's `inject.sh` scope.

To reset only the module's demo-web scenario without a full catch-up, run:

```bash
lab/10-day2-ops/restore.sh clean
```
