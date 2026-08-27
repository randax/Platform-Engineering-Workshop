#!/usr/bin/env bash
# Imperative leftovers of module 10 — all inherited from earlier modules:
# the app-assets bucket (module 03) and the in-cluster hello-site build
# (module 07; this module's apps/ still enables hello-site.yaml, whose image
# node-side pull image localhost:30500/hello-site:v1 only exists after that build).
# ArgoCD installs kagent itself, and its ModelConfig uses the attendee's
# host-side Ollama — whose address is a machine fact, so it is patched (not
# committed) from configmap kagent/cloudbox-host. The component's PostSync hook
# does that on a normal sync; this repeats it here because catch-up.sh
# force-pushes and does not wait for hook completion, and because a re-run must
# converge either way. Run by catch-up.sh after ArgoCD converges. Idempotent.
set -euo pipefail

SOLUTIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SOLUTIONS_DIR/.." && pwd)"

# The workshop-context guard: this step patches a live object, so it must never
# fire at whatever cluster kubectl happens to point at.
# shellcheck source=../../scripts/context-guard.sh
source "$REPO_ROOT/scripts/context-guard.sh"
require_workshop_context

# Module 09 inherits the bucket and build through its own chained post-step.
"$SOLUTIONS_DIR/module-09/post.sh"

# kagent's Ollama host — guarded on every side: the ConfigMap may be absent
# (docker/CI, where the git default is already right), kagent may not be
# enabled in this attendee's tree, and the value may already be correct.
ollama_host="$(kubectl -n kagent get configmap cloudbox-host \
  -o jsonpath='{.data.ollama}' 2>/dev/null || true)"
if [[ -n "${ollama_host}" ]] \
  && current="$(kubectl -n kagent get modelconfig default-model-config \
       -o jsonpath='{.spec.ollama.host}' 2>/dev/null)" \
  && [[ "${current}" != "${ollama_host}" ]]; then
  kubectl -n kagent patch modelconfig default-model-config --type merge \
    -p "{\"spec\":{\"ollama\":{\"host\":\"${ollama_host}\"}}}"
fi
