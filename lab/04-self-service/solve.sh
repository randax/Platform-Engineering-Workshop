#!/usr/bin/env bash
# Module 04 — full solution: ship the platform API and consume it.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
# shellcheck source=../common.sh
source "$REPO_ROOT/lab/common.sh"

# 1. One push: enable crossplane, ship XRD+Composition, create the first XR.
CLONE="$(gitops_clone)"
enable_catalog "$CLONE" crossplane.yaml
mkdir -p "$CLONE/gitops/components/platform-api" "$CLONE/gitops/components/demo"
cp "$LAB_DIR/platform/xrd.yaml"         "$CLONE/gitops/components/platform-api/"
cp "$LAB_DIR/platform/composition.yaml" "$CLONE/gitops/components/platform-api/"
cp "$LAB_DIR/platform-api-app.yaml"     "$CLONE/gitops/apps/platform-api.yaml"
cp "$LAB_DIR/examples/my-database.yaml" "$CLONE/gitops/components/demo/"
gitops_push "$CLONE" "module 04: crossplane + WorkshopDatabase API + my-db"

# 2. Wait for the machinery.
wait_app crossplane
wait_app platform-api
wait_app demo

kubectl wait --for=condition=Established \
  xrd/workshopdatabases.platform.cloudbox.io --timeout=180s

# 3. Wait for the developer's stack to be fully Ready (DB boot takes minutes).
kubectl -n demo wait --for=condition=Ready \
  workshopdatabase/my-db --timeout=600s

kubectl -n demo get workshopdatabase,cluster,job
