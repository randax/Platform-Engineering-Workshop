#!/usr/bin/env bash
# Module 06 — verify Knative serving, cold start, and scale-to-zero.
set -euo pipefail

FAILED=0
ok()   { echo "✅ $1"; }
fail() { echo "❌ FAIL: $1"; FAILED=$((FAILED + 1)); }

# --- Knative installed --------------------------------------------------------
ST="$(kubectl -n argocd get application knative-serving \
  -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || echo missing)"
if [ "$ST" = "Synced Healthy" ]; then
  ok "ArgoCD app 'knative-serving' is Synced/Healthy"
else
  fail "knative-serving app is '$ST' — cp gitops/catalog/knative-serving.yaml to gitops/apps/ and push"
fi

for d in activator autoscaler controller webhook; do
  if kubectl -n knative-serving wait --for=condition=Available "deploy/$d" --timeout=5s >/dev/null 2>&1; then
    ok "knative-serving/$d Available"
  else
    fail "knative-serving/$d not Available — kubectl -n knative-serving get pods"
  fi
done

# --- The ksvc ------------------------------------------------------------------
KSVC_READY="$(kubectl -n demo get ksvc hello \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [ "$KSVC_READY" = "True" ]; then
  ok "ksvc hello is Ready"
elif [ -z "$KSVC_READY" ]; then
  fail "no ksvc 'hello' in ns demo — push lab/06-serverless/hello-ksvc.yaml to gitops/components/demo/"
else
  fail "ksvc hello not Ready — kubectl -n demo describe ksvc hello (look at the conditions)"
fi

# --- Cold start / serving through Kourier ---------------------------------------
# Strip the scheme in pure bash — BSD sed has no \? in basic regex.
URL="$(kubectl -n demo get ksvc hello -o jsonpath='{.status.url}' 2>/dev/null || true)"
HOST="${URL#http://}"; HOST="${HOST#https://}"
if [ -n "$HOST" ]; then
  BODY="$(curl -fsS --max-time 30 -H "Host: $HOST" http://localhost:31080/ 2>/dev/null || true)"
  if echo "$BODY" | grep -qi hello; then
    ok "curl via Kourier (:31080, Host: $HOST) answered: $(echo "$BODY" | head -1)"
  else
    fail "no answer through Kourier — is 31080 up? kubectl get svc -A | grep 31080; try: curl -v -H 'Host: $HOST' http://localhost:31080/"
  fi
else
  fail "cannot determine ksvc URL — fix the ksvc checks above first"
fi

# --- Scale to zero ----------------------------------------------------------------
pod_count() {
  kubectl -n demo get pods -l serving.knative.dev/service=hello --no-headers 2>/dev/null | grep -cv Terminating || true
}
COUNT="$(pod_count)"
if [ "${COUNT:-0}" -eq 0 ]; then
  ok "hello is scaled to zero right now (pods exist only while requests flow)"
else
  echo "…waiting up to 150s for scale-to-zero (currently ${COUNT} pod(s); don't curl it now!)"
  WAITED=0
  while [ "$WAITED" -lt 150 ]; do
    sleep 10; WAITED=$((WAITED + 10))
    COUNT="$(pod_count)"
    [ "${COUNT:-0}" -eq 0 ] && break
  done
  if [ "${COUNT:-0}" -eq 0 ]; then
    ok "scale-to-zero observed after ~${WAITED}s of silence"
  else
    fail "still ${COUNT} pod(s) after ${WAITED}s idle — a loop still curling? min-scale set? kubectl -n knative-serving logs deploy/autoscaler --tail=20"
  fi
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED check(s) failed."
  exit 1
fi
echo "✅ Module 06 complete — serverless, minus the invoice."
