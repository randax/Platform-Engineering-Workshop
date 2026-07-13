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

# 2. Build inside the cluster.
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

# 3. Run the built image, delivered via GitOps.
CLONE="$(gitops_clone)"
mkdir -p "$CLONE/gitops/components/demo"
cp "$LAB_DIR/hello-site.yaml" "$CLONE/gitops/components/demo/hello-site.yaml"
gitops_push "$CLONE" "module 07: deploy hello-site from zot"

wait_app demo
kubectl -n demo rollout status deploy/hello-site --timeout=300s
