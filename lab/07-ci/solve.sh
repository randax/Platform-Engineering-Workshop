#!/usr/bin/env bash
# Module 07 — full solution: enable zot + argo-workflows, build in-cluster,
# deploy the result via GitOps.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
# shellcheck source=../common.sh
source "$REPO_ROOT/lab/common.sh"

# 1. Enable the pipeline machinery.
CLONE="$(gitops_clone)"
enable_catalog "$CLONE" zot.yaml argo-workflows.yaml
gitops_push "$CLONE" "module 07: enable zot + argo-workflows"

wait_app zot
wait_app argo-workflows
# wait_app returns on app HEALTH, but argo-workflows can be Healthy while still
# OutOfSync — the build-and-push WorkflowTemplate syncs a beat after the
# controller. Guard so the submit below can't race ahead of the template it
# references (else the Workflow errors "workflowtemplates ... build-and-push not
# found"). This is the exact case wait_exists exists for.
wait_exists builds workflowtemplate/build-and-push 180

# 2. Seed YOUR registry with the (pre-pulled) base image — the app's Dockerfile
#    builds FROM zot.zot.svc.cluster.local:5000, so the platform never touches
#    an external registry. Host-side crane against Zot's NodePort (plain HTTP).
#    SOURCE is the local cloudbox-mirror, not Docker Hub: busybox:1.37.0 is on
#    the pre-pull list, so it is already there, and Docker Hub is rate-limited
#    at the venue. Falls back to Docker Hub only if the mirror hasn't got it.
MIRROR="localhost:5001"     # cloudbox-mirror; MIRROR_PORT in scripts/versions.env
BUSYBOX="library/busybox:1.37.0"
# Probe the MANIFEST, not `/v2/`. `/v2/` answers "some registry is listening on
# :5001" and nothing about what is in it, so a mirror that is up but unfilled —
# a bare `docker run registry`, a purged volume, a cloudbox-init.sh that never
# finished — passed the old check, and crane was then pointed at a tag that is
# not there: `MANIFEST_UNKNOWN: manifest unknown`. The Docker Hub fallback sat
# right below, unused, because "reachable" had already been answered yes. That
# is exactly how the nightly rehearsal failed module 07.
if mise x crane@0.21.9 -- crane manifest --insecure "${MIRROR}/${BUSYBOX}" >/dev/null 2>&1; then
  BUSYBOX_SRC="${MIRROR}/${BUSYBOX}"
else
  echo "⚠️  cloudbox-mirror hasn't got ${BUSYBOX} — falling back to Docker Hub (needs internet)"
  BUSYBOX_SRC="docker.io/${BUSYBOX}"
fi
mise x crane@0.21.9 -- crane copy --insecure \
  "${BUSYBOX_SRC}" "localhost:30500/${BUSYBOX}"

# 3. Build inside the cluster.
WF_NAME="$(kubectl create -f "$LAB_DIR/workflow-run.yaml" -o jsonpath='{.metadata.name}')"
echo "submitted workflow: $WF_NAME"

WAITED=0
while true; do
  PHASE="$(kubectl -n builds get workflow "$WF_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$PHASE" in
    Succeeded) echo "workflow Succeeded"; break ;;
    Failed|Error) echo "workflow $PHASE" >&2; kubectl -n builds get workflow "$WF_NAME" -o yaml >&2; exit 1 ;;
  esac
  [ "$WAITED" -ge 900 ] && { echo "timed out waiting for build" >&2; exit 1; }
  sleep 15; WAITED=$((WAITED + 15))
done

curl -fsS http://localhost:30500/v2/_catalog

# 4. Run the built image, delivered via GitOps.
CLONE="$(gitops_clone)"
mkdir -p "$CLONE/gitops/components/demo"
cp "$LAB_DIR/hello-site.yaml" "$CLONE/gitops/components/demo/hello-site.yaml"
gitops_push "$CLONE" "module 07: deploy hello-site from zot"

# The demo app already exists and is Synced/Healthy from module 06, so a bare
# `wait_app demo` returns immediately on the PREVIOUS revision — before ArgoCD
# reconciles this hello-site commit — and the Deployment isn't there yet. Poll
# for it to actually appear (hard-refresh + wait), then gate on its rollout.
# (Same stale-revision race the wait_for_cr helper was built for, modules 03/04/06.)
wait_for_cr demo deploy/hello-site
kubectl -n demo rollout status deploy/hello-site --timeout=300s
