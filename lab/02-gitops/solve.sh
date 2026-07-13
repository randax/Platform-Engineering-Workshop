#!/usr/bin/env bash
# Module 02 — full solution: bootstrap GitOps and make the first change via git.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
# shellcheck source=../common.sh
source "$REPO_ROOT/lab/common.sh"

# 1. Bootstrap Gitea + ArgoCD and seed the repo (skip if already done).
if ! kubectl -n argocd get application platform >/dev/null 2>&1; then
  "$REPO_ROOT/scripts/bootstrap-gitops.sh"
fi
if ! curl -fsS --max-time 5 -u gitea_admin:cloudbox123 \
     http://localhost:30300/api/v1/repos/cloudbox/platform >/dev/null 2>&1; then
  "$REPO_ROOT/scripts/seed-gitea.sh"
fi

wait_app platform
wait_app local-path-provisioner
wait_app otel-lgtm

# 2. The GitOps change: demo Application + welcome ConfigMap, via git push.
CLONE="$(gitops_clone)"
cp "$LAB_DIR/demo-app.yaml" "$CLONE/gitops/apps/demo.yaml"
mkdir -p "$CLONE/gitops/components/demo"
sed 's/CHANGE ME/Cloudbox Attendee/' "$LAB_DIR/welcome.yaml" \
  > "$CLONE/gitops/components/demo/welcome.yaml"
gitops_push "$CLONE" "module 02: demo app with welcome configmap"

# 3. Watch it converge.
wait_app demo
kubectl -n demo get configmap welcome -o jsonpath='{.data.owner}'; echo
