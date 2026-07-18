#!/usr/bin/env bash
# Module 10 — verify Git is clean and the day-2 demo workload is healthy.
# Check-only: this script never commits, pushes, applies, patches, edits, or deletes.
#
# Target: the attendee's cloudbox/platform clone, gitops/components/demo/ —
# the same path module 02's "demo" Application (solutions/module-02/apps/demo.yaml)
# syncs into namespace demo. cloudbox/demo-app is unrelated Go source for
# module 07's in-cluster build and is never read here.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Runtime lookup is anchored to this script; ShellCheck cannot resolve $DIR.
# shellcheck disable=SC1091
source "$DIR/../common.sh"

WELCOME_PATH="gitops/components/demo/welcome.yaml"
COMPONENT_PATH="gitops/components/demo/demo-web.yaml"
BASELINE_SRC="$DIR/baseline/demo-web.yaml"
POISON_VALUE="8080-canary"
SCENARIO_TRAILER="Cloudbox-Scenario: day2-01"
FAILED=0

ok()   { echo "✅ $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

CLONE="$(gitops_clone)" || exit 1
TMP_PARENT="$(dirname "$CLONE")"
trap 'rm -rf "$TMP_PARENT"' EXIT

if [ ! -f "$CLONE/$WELCOME_PATH" ]; then
  fail "cloudbox/platform has no $WELCOME_PATH — enable module 02 first (see lab/02-gitops), then run ./verify.sh again"
  echo
  echo "❌ $FAILED check(s) failed. Follow the FAIL lines above, then run ./verify.sh again."
  exit 1
fi

if [ ! -f "$CLONE/$COMPONENT_PATH" ]; then
  fail "cloudbox/platform has no $COMPONENT_PATH — module 10's baseline hasn't been seeded yet; run ./inject.sh 1 once to seed it, wait for ArgoCD, then run ./inject.sh 1 again to inject the fault"
  echo
  echo "❌ $FAILED check(s) failed. Follow the FAIL lines above, then run ./verify.sh again."
  exit 1
fi

if grep -Fq -- "$POISON_VALUE" "$CLONE/$COMPONENT_PATH"; then
  fail "scenario 1 is still present in Git ($COMPONENT_PATH contains $POISON_VALUE) — inspect git log, then run git revert <scenario-commit> && git push"

  # The Git marker is authoritative. Live probes only confirm that the injected
  # commit has produced the intended failure, and are deliberately short-lived.
  if ! command -v kubectl >/dev/null 2>&1 || \
    ! kubectl --request-timeout=3s get namespace demo >/dev/null 2>&1; then
    fail "could not confirm scenario 1's live symptoms — restore cluster access, then run kubectl -n demo get pods -l app=demo-web"
  else
    POD_STATE="$(kubectl --request-timeout=3s -n demo get pods -l app=demo-web \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .status.containerStatuses[*]}{.state.waiting.reason}{":"}{.restartCount}{","}{end}{"\n"}{end}' \
      2>/dev/null || true)"
    if printf '%s\n' "$POD_STATE" | grep -Fq 'CrashLoopBackOff'; then
      ok "scenario 1 confirmed live: a demo-web pod is CrashLoopBackOff"
    else
      fail "Git is poisoned but no demo-web pod reports CrashLoopBackOff yet — wait for ArgoCD, then run kubectl -n demo describe pod <new-pod>"
    fi

    if kubectl --request-timeout=3s -n demo rollout status deploy/demo-web \
      --timeout=5s >/dev/null 2>&1; then
      fail "Git is poisoned but the demo-web rollout reports complete — inspect the ArgoCD Application and run kubectl -n demo get rs,pods"
    else
      ok "scenario 1 confirmed live: the demo-web rollout is not completing"
    fi
  fi
else
  if git -C "$CLONE" log --format='%H' --grep="$SCENARIO_TRAILER" -n 1 | grep -q .; then
    ok "scenario 1 fixed: the poison value is absent from cloudbox/platform:main"
  else
    ok "scenario 1 was never injected (repository is clean)"
  fi

  # "Repo clean" means gitops/components/demo/demo-web.yaml matches this
  # module's own baseline byte-for-byte — not just "no poison substring" —
  # so a leftover, half-reverted, or hand-edited manifest is still caught.
  if cmp -s "$CLONE/$COMPONENT_PATH" "$BASELINE_SRC"; then
    ok "gitops/components/demo/demo-web.yaml matches the module's baseline"
  else
    fail "gitops/components/demo/demo-web.yaml no longer matches lab/10-day2-ops/baseline/demo-web.yaml — diff them and revert any leftover edit"
  fi

  # welcome.yaml is the attendee's own module-02 customization (their name goes
  # in `owner`), so we cannot diff it against a fixed baseline — but our own
  # commits only ever `git add` the demo-web.yaml path (never -A), so this is a
  # sanity check that our scripts left it alone, not a content comparison.
  if grep -q '^kind: ConfigMap' "$CLONE/$WELCOME_PATH" && \
    grep -q 'name: welcome' "$CLONE/$WELCOME_PATH"; then
    ok "welcome.yaml is untouched (still a ConfigMap named welcome)"
  else
    fail "gitops/components/demo/welcome.yaml no longer looks like module 02's ConfigMap — inspect git log for an unrelated change"
  fi

  # Git-clean and live-healthy are separate, unconditional checks. Together they
  # catch a live-only edit: ArgoCD selfHeal makes Git the durable source of truth.
  if command -v kubectl >/dev/null 2>&1 && \
    kubectl --request-timeout=3s -n demo rollout status deploy/demo-web \
      --timeout=20s >/dev/null 2>&1; then
    ok "demo-web rollout is healthy"
  else
    fail "demo-web rollout is not healthy or the cluster is unreachable — run kubectl -n demo rollout status deploy/demo-web, then fix Git and retry"
  fi

  POD_STATE=""
  if command -v kubectl >/dev/null 2>&1; then
    POD_STATE="$(kubectl --request-timeout=3s -n demo get pods -l app=demo-web \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .status.containerStatuses[*]}{.state.waiting.reason}{":"}{.restartCount}{","}{end}{"\n"}{end}' \
      2>/dev/null || true)"
  fi
  if [ -z "$POD_STATE" ]; then
    fail "no demo-web pod status was readable — run kubectl -n demo get pods -l app=demo-web and restore cluster access or the workload"
  elif printf '%s\n' "$POD_STATE" | grep -Fq 'CrashLoopBackOff'; then
    fail "a demo-web pod is still CrashLoopBackOff — run kubectl -n demo logs <pod> --previous and inspect the Git-managed Deployment"
  elif printf '%s\n' "$POD_STATE" | awk -F '[:|,]' '
    { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/ && $i > 3) found = 1 }
    END { exit(found ? 0 : 1) }
  '; then
    fail "a demo-web container has more than 3 restarts — run kubectl -n demo describe pod <pod> and confirm the rollout has stabilized"
  else
    ok "demo-web pods have no CrashLoopBackOff or high restart counts"
  fi
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED check(s) failed. Follow the FAIL lines above, then run ./verify.sh again."
  exit 1
fi
echo "✅ Module 10 scenario complete — Git is clean and demo-web is healthy."
