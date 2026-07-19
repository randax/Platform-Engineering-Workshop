#!/usr/bin/env bash
# Imperative leftovers of module 10 — all inherited from earlier modules:
# the app-assets bucket (module 03) and the in-cluster hello-site build
# (module 07; this module's apps/ still enables hello-site.yaml, whose image
# localhost:30500/hello-site:v1 only exists after that build).
# No kagent step: ArgoCD installs it, and its ModelConfig uses the attendee's host-side Ollama.
# Run by catch-up.sh after ArgoCD converges. Idempotent.
set -euo pipefail

SOLUTIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Module 09 inherits the bucket and build through its own chained post-step.
"$SOLUTIONS_DIR/module-09/post.sh"
