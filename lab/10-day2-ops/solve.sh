#!/usr/bin/env bash
# Canonical answer for attendees and the CI solve -> verify regression.
#
# verify.sh grades two things, so the module's end state has two halves:
#   1. the demo-web baseline exists in cloudbox/platform and is rolled out.
#      On a fresh cluster nothing has seeded it yet (that normally happens on
#      the first ./inject.sh run), so seed it here — otherwise a standalone
#      solve exits 0 having done nothing and verify then fails, breaking the
#      solve<->verify contract (rehearsal 9, finding 09);
#   2. no injected fault remains — restore.sh all reverts whatever is live.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Runtime lookup is anchored to this script; ShellCheck cannot resolve $DIR.
# shellcheck disable=SC1091
source "$DIR/../common.sh"

COMPONENT_PATH="gitops/components/demo/demo-web.yaml"

CLONE="$(gitops_clone)" || exit 1
TMP_PARENT="$(dirname "$CLONE")"
trap 'rm -rf "$TMP_PARENT"' EXIT

if [ ! -f "$CLONE/$COMPONENT_PATH" ]; then
  echo "🌱 No demo-web baseline in cloudbox/platform yet (fresh lab) — seeding it,"
  echo "   the same seed the first ./inject.sh run performs."
  mkdir -p "$(dirname "$CLONE/$COMPONENT_PATH")"
  cp "$DIR/baseline/demo-web.yaml" "$CLONE/$COMPONENT_PATH"
  git -C "$CLONE" add "$COMPONENT_PATH"
  git -C "$CLONE" -c user.name="cloudbox" -c user.email="cloudbox@localhost" \
    commit -q -m "chore(demo): seed the demo-web baseline workload"
  git -C "$CLONE" push -q origin main
  argocd_refresh demo
else
  echo "demo-web baseline already in cloudbox/platform — reverting any injected fault."
fi

"$DIR/restore.sh" all

wait_exists demo deploy/demo-web 180
kubectl -n demo rollout status deploy/demo-web --timeout=300s
