#!/usr/bin/env bash
# Imperative leftovers of module 09 — all inherited from earlier modules:
# the app-assets bucket (module 03) and the in-cluster hello-site build
# (module 07; this module's apps/ still enables hello-site.yaml, whose image
# localhost:30500/hello-site:v1 only exists after that build). Module 09's
# own images bucket needs no post-step: a Job inside the picture-pipeline
# component creates it. Run by catch-up.sh after ArgoCD converges. Idempotent.
set -euo pipefail

SOLUTIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Bucket + build (module 07's post.sh chains module 03's itself).
"$SOLUTIONS_DIR/module-07/post.sh"
