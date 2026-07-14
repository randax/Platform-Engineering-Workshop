#!/usr/bin/env bash
# Module 08 — full solution: enable the Cloudbox Console, then create the
# star-task database. The lab does that through the console's form; here we
# create the identical WorkshopDatabase via kubectl (the form is sugar over
# the same API call — that's the module's point).
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
# shellcheck source=../common.sh
source "$REPO_ROOT/lab/common.sh"

CLONE="$(gitops_clone)"
enable_catalog "$CLONE" portal.yaml
gitops_push "$CLONE" "module 08: enable the cloudbox console"

wait_app portal

# Wait until the UI actually answers on the NodePort.
WAITED=0
until curl -fsS --max-time 5 -o /dev/null http://localhost:30600/ 2>/dev/null; do
  [ "$WAITED" -ge 300 ] && { echo "timed out waiting for the console UI" >&2; exit 1; }
  sleep 10; WAITED=$((WAITED + 10))
done
echo "Cloudbox Console is up: http://localhost:30600"

# The star task, non-UI path: same object the "New database" form creates.
kubectl -n demo apply -f - <<'EOF'
apiVersion: platform.cloudbox.io/v1alpha1
kind: WorkshopDatabase
metadata:
  name: console-db
spec:
  size: small
  storageGB: 1
EOF

kubectl -n demo wait --for=condition=Ready workshopdatabase/console-db --timeout=600s
echo "console-db is Ready — see it on http://localhost:30600/databases"
