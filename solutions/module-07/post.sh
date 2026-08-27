#!/usr/bin/env bash
# Imperative leftovers of module 07: the app-assets bucket (from module 03)
# and the in-cluster image build (hello-site deployment stays in
# ImagePullBackOff until the workflow has pushed the image; kubelet backoff
# recovers on its own afterwards). Run by catch-up.sh after ArgoCD converges.
set -euo pipefail

SOLUTIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SOLUTIONS_DIR/.." && pwd)"

# The workshop-context guard. Normally reached through catch-up.sh, which guards
# already — but this post-step is independently executable: modules 08, 09 and 10
# run it directly, and so does a maintainer debugging the recovery path. It
# creates an Argo Workflow and rolls a Deployment in whatever cluster kubectl
# points at. One copy of the guard, in scripts/context-guard.sh.
# shellcheck source=../../scripts/context-guard.sh
source "$REPO_ROOT/scripts/context-guard.sh"
require_workshop_context

# shellcheck source=../../scripts/versions.env
source "$REPO_ROOT/scripts/versions.env"
ZOT_HOST="${ZOT_HOST_URL#http://}"

# 1. Bucket (same as module 03).
"$SOLUTIONS_DIR/module-03/post.sh"

# 2. Build hello-site in-cluster if Zot doesn't have it yet.
if curl -fsS --max-time 5 "${ZOT_HOST_URL}/v2/_catalog" 2>/dev/null | grep -q hello-site; then
  echo "✅ hello-site already in Zot — skipping build"
  exit 0
fi

# 2a. Seed Zot with the base image the Dockerfile builds FROM
#     (zot.zot.svc.cluster.local:5000/library/busybox). Idempotent.
#     Source it from the local cloudbox-mirror, which the pre-pull already
#     filled with busybox:1.37.0 — catch-up.sh is the recovery path AT THE
#     VENUE, so it must not reach for Docker Hub (rate-limited there, and
#     unreachable if the WiFi has given up). Same logic as lab/07-ci/solve.sh
#     and the module README; fall back to Docker Hub only if the mirror lacks it.
MIRROR="localhost:5001"     # MIRROR_PORT in scripts/versions.env
BUSYBOX="library/busybox:1.37.0"
# Probe the MANIFEST, not `/v2/` — see the same block in lab/07-ci/solve.sh. A
# reachable-but-unfilled mirror answered `/v2/` happily and then failed the copy
# with MANIFEST_UNKNOWN, without ever trying the fallback below. This is the
# recovery path, so a wrong answer here strands someone mid-workshop.
if mise x crane@0.21.9 -- crane manifest --insecure "${MIRROR}/${BUSYBOX}" >/dev/null 2>&1; then
  BUSYBOX_SRC="${MIRROR}/${BUSYBOX}"
else
  echo "⚠️  cloudbox-mirror hasn't got ${BUSYBOX} — falling back to Docker Hub (needs internet)" >&2
  BUSYBOX_SRC="docker.io/${BUSYBOX}"
fi
mise x crane@0.21.9 -- crane copy --insecure \
  "${BUSYBOX_SRC}" "${ZOT_HOST}/${BUSYBOX}"

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
