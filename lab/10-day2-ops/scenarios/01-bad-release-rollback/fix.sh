#!/usr/bin/env bash
# Canonical repair for scenario 01: revert the traced release commit and push.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Runtime lookup is anchored to this script; ShellCheck cannot resolve $DIR.
# shellcheck disable=SC1091
source "$DIR/../../../common.sh"

DEMO_REPO_URL="${DEMO_REPO_URL:-http://gitea_admin:cloudbox123@${GITEA_HOST}/cloudbox/demo-app.git}"
DEPLOYMENT_PATH="deploy/deployment.yaml"
POISON_VALUE="8080-canary"
SCENARIO_TRAILER="Cloudbox-Scenario: day2-01"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
CLONE="$TMP_ROOT/demo-app"

if ! git clone --quiet --depth 100 --branch main --single-branch \
  "$DEMO_REPO_URL" "$CLONE" 2>/dev/null; then
  echo "ERROR: could not clone http://${GITEA_HOST}/cloudbox/demo-app.git — is Gitea running and seeded?" >&2
  exit 1
fi

if [ ! -f "$CLONE/$DEPLOYMENT_PATH" ] || \
  ! grep -Fq -- "$POISON_VALUE" "$CLONE/$DEPLOYMENT_PATH"; then
  echo "scenario 1 was never injected — skipping"
  exit 0
fi

INJECTED_SHA="$(git -C "$CLONE" log --format='%H' \
  --grep="$SCENARIO_TRAILER" -n 1 -- "$DEPLOYMENT_PATH")"
if [ -z "$INJECTED_SHA" ]; then
  echo "ERROR: $POISON_VALUE is present, but no '$SCENARIO_TRAILER' commit was found." >&2
  echo "Inspect git log and revert the commit that introduced the PORT value manually." >&2
  exit 1
fi

if ! git -C "$CLONE" -c user.name="cloudbox" -c user.email="cloudbox@localhost" \
  revert --no-edit "$INJECTED_SHA"; then
  echo "ERROR: git revert conflicted — inspect the commits after ${INJECTED_SHA:0:12} and revert the PORT change manually." >&2
  exit 1
fi
REVERT_SHA="$(git -C "$CLONE" rev-parse --short HEAD)"
git -C "$CLONE" push -q origin main

# Discover the direct-repo Application instead of guessing the packaging slice's
# name. This is only a best-effort nudge; normal ArgoCD polling remains reliable.
if command -v kubectl >/dev/null 2>&1; then
  APPLICATIONS="$(kubectl --request-timeout=3s -n argocd get applications \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.source.repoURL}{"\n"}{end}' \
    2>/dev/null || true)"
  while IFS='|' read -r app_name repo_url; do
    case "$repo_url" in
      */cloudbox/demo-app|*/cloudbox/demo-app.git)
        kubectl --request-timeout=3s -n argocd annotate application "$app_name" \
          argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
        ;;
    esac
  done <<< "$APPLICATIONS"
fi

echo "✅ scenario 1 restored with revert commit $REVERT_SHA"
