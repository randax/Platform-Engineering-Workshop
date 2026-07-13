#!/usr/bin/env bash
# Module 02 — verify the GitOps loop end to end.
set -euo pipefail

FAILED=0
ok()   { echo "✅ $1"; }
fail() { echo "❌ FAIL: $1"; FAILED=$((FAILED + 1)); }

app_status() { # <name> -> "<sync> <health>"
  kubectl -n argocd get application "$1" \
    -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || echo "missing missing"
}

check_app() { # <name>
  local st; st="$(app_status "$1")"
  if [ "$st" = "Synced Healthy" ]; then
    ok "ArgoCD app '$1' is Synced/Healthy"
  else
    fail "ArgoCD app '$1' is '$st' (want 'Synced Healthy') — open http://localhost:30080 or: kubectl -n argocd get app $1 -o yaml"
  fi
}

# --- Gitea -------------------------------------------------------------------
if curl -fsS --max-time 5 http://localhost:30300/api/healthz >/dev/null 2>&1 \
   || curl -fsS --max-time 5 http://localhost:30300/ >/dev/null 2>&1; then
  ok "Gitea answers on http://localhost:30300"
else
  fail "Gitea not reachable on :30300 — did ./scripts/bootstrap-gitops.sh run? kubectl -n gitea get pods"
fi

if curl -fsS --max-time 5 -u gitea_admin:cloudbox123 \
     http://localhost:30300/api/v1/repos/cloudbox/platform >/dev/null 2>&1; then
  ok "repo cloudbox/platform exists in Gitea"
else
  fail "cloudbox/platform repo missing in Gitea — run ./scripts/seed-gitea.sh"
fi

# --- ArgoCD ------------------------------------------------------------------
if curl -fsSk --max-time 5 -o /dev/null http://localhost:30080/ 2>/dev/null \
   || curl -fsSk --max-time 5 -o /dev/null https://localhost:30080/ 2>/dev/null; then
  ok "ArgoCD UI answers on :30080"
else
  fail "ArgoCD UI not reachable on :30080 — kubectl -n argocd get pods,svc"
fi

REPO_URL="$(kubectl -n argocd get application platform -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || true)"
if echo "$REPO_URL" | grep -q gitea; then
  ok "root app 'platform' watches the in-cluster Gitea ($REPO_URL)"
elif [ -n "$REPO_URL" ]; then
  fail "root app watches '$REPO_URL' — it must point at the in-cluster Gitea, never GitHub; re-run ./scripts/bootstrap-gitops.sh"
else
  fail "no root Application 'platform' found in ns argocd — run ./scripts/bootstrap-gitops.sh"
fi

check_app platform
check_app local-path-provisioner
check_app otel-lgtm

# --- Wave-0 side effects -------------------------------------------------------
if kubectl get storageclass local-path >/dev/null 2>&1; then
  ok "storageclass 'local-path' exists (wave 0)"
else
  fail "storageclass 'local-path' missing — is the local-path-provisioner app synced?"
fi

OBS_RUNNING="$(kubectl -n observability get pods --no-headers 2>/dev/null | awk '$3 == "Running"' | wc -l | tr -d ' ')"
if [ "${OBS_RUNNING:-0}" -ge 1 ]; then
  ok "observability stack running in ns 'observability'"
else
  fail "no running pods in ns 'observability' — kubectl -n observability get pods; check the otel-lgtm app in ArgoCD"
fi

# --- Your GitOps change --------------------------------------------------------
check_app demo

OWNER="$(kubectl -n demo get configmap welcome -o jsonpath='{.data.owner}' 2>/dev/null || true)"
if [ -z "$OWNER" ]; then
  fail "ConfigMap 'welcome' not found in ns demo — did you push gitops/apps/demo.yaml AND gitops/components/demo/welcome.yaml to Gitea? (ArgoCD polls ~3 min; Refresh in the UI to hurry it)"
elif [ "$OWNER" = "CHANGE ME" ]; then
  fail "welcome ConfigMap still says owner='CHANGE ME' — edit it in the GIT REPO (not kubectl edit!) and push"
else
  ok "welcome ConfigMap delivered via git — owner: $OWNER"
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED check(s) failed. Catch-up if needed: ./scripts/catch-up.sh 02"
  exit 1
fi
echo "✅ Module 02 complete — git is now the only door. Two-minute explain-back time."
