#!/usr/bin/env bash
# Module 08 — full solution: enable backstage and wait for the portal.
# (The template-run part of the module is UI-driven and intentionally not scripted.)
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
# shellcheck source=../common.sh
source "$REPO_ROOT/lab/common.sh"

CLONE="$(gitops_clone)"
enable_catalog "$CLONE" backstage.yaml
gitops_push "$CLONE" "module 08: enable backstage"

wait_app backstage 600

# Wait until the UI actually answers (slow first boot).
WAITED=0
until curl -fsS --max-time 5 -o /dev/null http://localhost:30700/ 2>/dev/null; do
  [ "$WAITED" -ge 600 ] && { echo "timed out waiting for Backstage UI" >&2; exit 1; }
  sleep 15; WAITED=$((WAITED + 15))
done
echo "Backstage is up: http://localhost:30700 (guest sign-in)"
