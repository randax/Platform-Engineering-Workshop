#!/usr/bin/env bash
# Module 08 — verify the Backstage portal is up and functional.
set -euo pipefail

FAILED=0
ok()   { echo "✅ $1"; }
fail() { echo "❌ FAIL: $1"; FAILED=$((FAILED + 1)); }

ST="$(kubectl -n argocd get application backstage \
  -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || echo missing)"
if [ "$ST" = "Synced Healthy" ]; then
  ok "ArgoCD app 'backstage' is Synced/Healthy"
else
  fail "backstage app is '$ST' — cp gitops/catalog/backstage.yaml to gitops/apps/ and push (then give it a few minutes, it's the heavy one)"
fi

# --- Deployments ready -----------------------------------------------------
BS_READY="$(kubectl -n backstage get deploy --no-headers 2>/dev/null | awk '{split($2,a,"/"); if (a[1]==a[2] && a[1]>0) n++} END {print n+0}')"
BS_TOTAL="$(kubectl -n backstage get deploy --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "${BS_TOTAL:-0}" -ge 1 ] && [ "$BS_READY" = "$BS_TOTAL" ]; then
  ok "all $BS_TOTAL deployment(s) in ns backstage are ready"
elif [ "${BS_TOTAL:-0}" -eq 0 ]; then
  fail "no deployments in ns backstage — is the app synced? kubectl -n backstage get all"
else
  fail "only $BS_READY/$BS_TOTAL backstage deployments ready — kubectl -n backstage get pods (first boot is slow; OOM on 16GB machines is the usual suspect)"
fi

# --- UI answers --------------------------------------------------------------
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:30700/ 2>/dev/null || echo 000)"
if [ "$HTTP_CODE" = "200" ]; then
  ok "Backstage UI answers on :30700"
else
  fail "no UI on :30700 (HTTP $HTTP_CODE) — kubectl -n backstage get svc; pod logs if pending"
fi

# --- Catalog API answers -------------------------------------------------------
# 200 = open access; 401 = up but wants a token — both prove the backend + catalog
# plugin are alive, which is what we're checking.
CAT_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:30700/api/catalog/entities 2>/dev/null || echo 000)"
if [ "$CAT_CODE" = "200" ] || [ "$CAT_CODE" = "401" ]; then
  ok "catalog API responds on /api/catalog/entities (HTTP $CAT_CODE)"
else
  fail "catalog API not responding (HTTP $CAT_CODE) — kubectl -n backstage logs deploy/backstage --tail=50 (DB connection issues show here)"
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED check(s) failed. Backstage is the presenter-fallback module — if the room is short on time or RAM, watch the loop on the projector."
  exit 1
fi
echo "✅ Module 08 complete — your platform has a front door. That's the whole tour."
