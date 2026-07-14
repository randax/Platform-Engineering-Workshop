#!/usr/bin/env bash
# Imperative leftovers of module 07: the app-assets bucket (from module 03)
# and the in-cluster image build (hello-site deployment stays in
# ImagePullBackOff until the workflow has pushed the image; kubelet backoff
# recovers on its own afterwards). Run by catch-up.sh after ArgoCD converges.
set -euo pipefail

SOLUTIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SOLUTIONS_DIR/.." && pwd)"

# 1. Bucket (same as module 03).
"$SOLUTIONS_DIR/module-03/post.sh"

# 2. Build hello-site in-cluster if Zot doesn't have it yet.
if curl -fsS --max-time 5 http://localhost:30500/v2/_catalog 2>/dev/null | grep -q hello-site; then
  echo "✅ hello-site already in Zot — skipping build"
  exit 0
fi

# 2a. Seed Zot with the base image the Dockerfile builds FROM
#     (zot.zot.svc.cluster.local:5000/library/busybox). Idempotent.
mise x crane@0.21.7 -- crane copy --insecure \
  docker.io/library/busybox:1.37.0 localhost:30500/library/busybox:1.37.0

WF_NAME="$(kubectl create -f "$REPO_ROOT/lab/07-ci/workflow-run.yaml" -o jsonpath='{.metadata.name}')"
echo "submitted build workflow: $WF_NAME"

WAITED=0
while true; do
  PHASE="$(kubectl -n builds get workflow "$WF_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$PHASE" in
    Succeeded) echo "✅ build Succeeded"; break ;;
    Failed|Error) echo "ERROR: build workflow $PHASE" >&2; exit 1 ;;
  esac
  [ "$WAITED" -ge 900 ] && { echo "ERROR: build timed out" >&2; exit 1; }
  sleep 15; WAITED=$((WAITED + 15))
done

# Nudge the stuck deployment instead of waiting out image-pull backoff.
kubectl -n demo delete pods -l app=hello-site --ignore-not-found
kubectl -n demo rollout status deploy/hello-site --timeout=300s || true
