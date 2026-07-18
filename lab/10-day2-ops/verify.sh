#!/usr/bin/env bash
# Module 10 — verify Git is clean and the day-2 demo workload is healthy.
# Check-only: this script never commits, pushes, applies, patches, edits, or deletes.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Runtime lookup is anchored to this script; ShellCheck cannot resolve $DIR.
# shellcheck disable=SC1091
source "$DIR/../common.sh"

DEMO_REPO_URL="${DEMO_REPO_URL:-http://gitea_admin:cloudbox123@${GITEA_HOST}/cloudbox/demo-app.git}"
DEPLOYMENT_PATH="deploy/deployment.yaml"
POISON_VALUE="8080-canary"
SCENARIO_TRAILER="Cloudbox-Scenario: day2-01"
FAILED=0

ok()   { echo "✅ $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
CLONE="$TMP_ROOT/demo-app"

if ! git clone --quiet --depth 100 --branch main --single-branch \
  "$DEMO_REPO_URL" "$CLONE" 2>/dev/null; then
  fail "could not read http://${GITEA_HOST}/cloudbox/demo-app.git — make sure Gitea is running and module 10's day-2 demo app is enabled, then run ./verify.sh again"
  echo
  echo "❌ $FAILED check(s) failed. Follow the FAIL lines above, then run ./verify.sh again."
  exit 1
fi

if [ ! -f "$CLONE/$DEPLOYMENT_PATH" ]; then
  fail "cloudbox/demo-app has no $DEPLOYMENT_PATH — enable module 10's packaging/day-2 setup, then run ./verify.sh again"
  echo
  echo "❌ $FAILED check(s) failed. Follow the FAIL lines above, then run ./verify.sh again."
  exit 1
fi

if grep -Fq -- "$POISON_VALUE" "$CLONE/$DEPLOYMENT_PATH"; then
  fail "scenario 1 is still present in Git ($DEPLOYMENT_PATH contains $POISON_VALUE) — inspect git log, then run git revert <scenario-commit> && git push"

  # The Git marker is authoritative. Live probes only confirm that the injected
  # commit has produced the intended failure, and are deliberately short-lived.
  if ! command -v kubectl >/dev/null 2>&1 || \
    ! kubectl --request-timeout=3s get namespace demo >/dev/null 2>&1; then
    fail "could not confirm scenario 1's live symptoms — restore cluster access, then run kubectl -n demo get pods -l app=demo-app"
  else
    POD_STATE="$(kubectl --request-timeout=3s -n demo get pods -l app=demo-app \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .status.containerStatuses[*]}{.state.waiting.reason}{":"}{.restartCount}{","}{end}{"\n"}{end}' \
      2>/dev/null || true)"
    if printf '%s\n' "$POD_STATE" | grep -Fq 'CrashLoopBackOff'; then
      ok "scenario 1 confirmed live: a demo-app pod is CrashLoopBackOff"
    else
      fail "Git is poisoned but no demo-app pod reports CrashLoopBackOff yet — wait for ArgoCD, then run kubectl -n demo describe pod <new-pod>"
    fi

    if kubectl --request-timeout=3s -n demo rollout status deploy/demo-app \
      --timeout=5s >/dev/null 2>&1; then
      fail "Git is poisoned but the demo-app rollout reports complete — inspect the ArgoCD Application and run kubectl -n demo get rs,pods"
    else
      ok "scenario 1 confirmed live: the demo-app rollout is not completing"
    fi
  fi
else
  if git -C "$CLONE" log --format='%H' --grep="$SCENARIO_TRAILER" -n 1 | grep -q .; then
    ok "scenario 1 fixed: the poison value is absent from cloudbox/demo-app:main"
  else
    ok "scenario 1 was never injected (repository is clean)"
  fi

  # Git-clean and live-healthy are separate, unconditional checks. Together they
  # catch a live-only edit: ArgoCD selfHeal makes Git the durable source of truth.
  if command -v kubectl >/dev/null 2>&1 && \
    kubectl --request-timeout=3s -n demo rollout status deploy/demo-app \
      --timeout=20s >/dev/null 2>&1; then
    ok "demo-app rollout is healthy"
  else
    fail "demo-app rollout is not healthy or the cluster is unreachable — run kubectl -n demo rollout status deploy/demo-app, then fix Git and retry"
  fi

  POD_STATE=""
  if command -v kubectl >/dev/null 2>&1; then
    POD_STATE="$(kubectl --request-timeout=3s -n demo get pods -l app=demo-app \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .status.containerStatuses[*]}{.state.waiting.reason}{":"}{.restartCount}{","}{end}{"\n"}{end}' \
      2>/dev/null || true)"
  fi
  if [ -z "$POD_STATE" ]; then
    fail "no demo-app pod status was readable — run kubectl -n demo get pods -l app=demo-app and restore cluster access or the workload"
  elif printf '%s\n' "$POD_STATE" | grep -Fq 'CrashLoopBackOff'; then
    fail "a demo-app pod is still CrashLoopBackOff — run kubectl -n demo logs <pod> --previous and inspect the Git-managed Deployment"
  elif printf '%s\n' "$POD_STATE" | awk -F '[:|,]' '
    { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/ && $i > 3) found = 1 }
    END { exit(found ? 0 : 1) }
  '; then
    fail "a demo-app container has more than 3 restarts — run kubectl -n demo describe pod <pod> and confirm the rollout has stabilized"
  else
    ok "demo-app pods have no CrashLoopBackOff or high restart counts"
  fi
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED check(s) failed. Follow the FAIL lines above, then run ./verify.sh again."
  exit 1
fi
echo "✅ Module 10 scenario complete — Git is clean and demo-app is healthy."
