#!/usr/bin/env bash
# =============================================================================
# bootstrap-gitops.sh — module 2: install Gitea + ArgoCD (the GitOps engine)
#
# This is the only imperative install in the workshop — everything after this
# is delivered as ArgoCD Applications from the in-cluster Gitea. It installs:
#
#   1. local-path-provisioner (vendored manifest) — Gitea's PVC needs a
#      storage class before GitOps exists; ArgoCD adopts it in wave 0 later
#   2. Gitea (official chart, pinned) — single-pod SQLite mode, push-to-create
#      enabled, admin gitea_admin/cloudbox123, NodePort 30300
#   3. ArgoCD (vendored install.yaml, pinned) — NodePort 30080, plus the
#      Application-CRD health check in argocd-cm (without it, app-of-apps
#      sync waves don't gate — the most-missed step; see docs/RESEARCH.md §3)
#
# Usage:
#   ./scripts/bootstrap-gitops.sh
#
# Requires: a running cluster (./scripts/create-cluster.sh) and internet OR a
# filled cloudbox-mirror (the Helm chart itself is fetched from the repo cache).
# Idempotent: safe to re-run.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

need kubectl
need helm

kubectl get nodes >/dev/null 2>&1 \
  || die "Cannot reach a cluster. Run ./scripts/create-cluster.sh first."

# --- 1. Storage class -----------------------------------------------------------
step "Installing local-path-provisioner ${LOCAL_PATH_PROVISIONER_VERSION} (storage for Gitea)"
# Server-side apply so the wave-0 ArgoCD Application can adopt these resources
# later without field-ownership conflicts.
kubectl apply --server-side --force-conflicts \
  -f "${SCRIPT_DIR}/manifests/local-path-storage-${LOCAL_PATH_PROVISIONER_VERSION}.yaml"
kubectl annotate storageclass local-path \
  storageclass.kubernetes.io/is-default-class=true --overwrite >/dev/null
kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=180s
ok "Default storage class 'local-path' ready"

# --- 2. Gitea ----------------------------------------------------------------------
step "Installing Gitea (chart ${GITEA_CHART_VERSION}) — your cloud's git server"
helm repo add gitea-charts "${GITEA_HELM_REPO}" --force-update >/dev/null

# Single-pod mode: SQLite + in-memory cache/session, no HA subcharts. This is
# a workshop git server for ~1 user, not a production forge — and that is fine.
# Values are fed on stdin (-f -) to keep everything in this one readable file.
helm upgrade --install gitea gitea-charts/gitea \
  --version "${GITEA_CHART_VERSION}" \
  --namespace gitea --create-namespace \
  -f - <<EOF
image:
  rootless: true

service:
  http:
    type: NodePort
    nodePort: ${NODEPORT_GITEA}
    clusterIP: ""

# Disable all HA subcharts — single pod, SQLite on a PVC.
postgresql:
  enabled: false
postgresql-ha:
  enabled: false
valkey:
  enabled: false
valkey-cluster:
  enabled: false

persistence:
  enabled: true
  size: 5Gi

gitea:
  admin:
    username: ${GITEA_ADMIN_USER}
    password: ${GITEA_ADMIN_PASSWORD}
    email: ${GITEA_ADMIN_USER}@cloudbox.local
  config:
    database:
      DB_TYPE: sqlite3
    session:
      PROVIDER: memory
    cache:
      ADAPTER: memory
    queue:
      TYPE: level
    repository:
      # push-to-create: pushing to a repo that does not exist yet creates it
      ENABLE_PUSH_CREATE_USER: true
      ENABLE_PUSH_CREATE_ORG: true
      # ArgoCD polls anonymously — repos must be born public
      DEFAULT_PUSH_CREATE_PRIVATE: false
    server:
      DOMAIN: gitea-http.gitea.svc.cluster.local
      ROOT_URL: ${GITEA_CLUSTER_URL}/
EOF

# --- 3. ArgoCD ------------------------------------------------------------------------
step "Installing ArgoCD ${ARGOCD_VERSION} (vendored manifest — no internet needed)"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# --server-side: the ApplicationSet CRD exceeds client-side annotation limits.
kubectl apply --server-side --force-conflicts -n argocd \
  -f "${SCRIPT_DIR}/manifests/argocd-install-${ARGOCD_VERSION}.yaml"

info "Restoring the Application-CRD health check (argocd-cm) so sync waves gate"
kubectl patch configmap argocd-cm -n argocd --type merge --patch-file /dev/stdin <<'EOF'
data:
  resource.customizations.health.argoproj.io_Application: |
    hs = {}
    hs.status = "Progressing"
    hs.message = ""
    if obj.status ~= nil then
      if obj.status.health ~= nil then
        hs.status = obj.status.health.status
        if obj.status.health.message ~= nil then
          hs.message = obj.status.health.message
        end
      end
    end
    return hs
EOF

info "Creating read-only 'backstage' ArgoCD account (used by the module-08 portal)"
kubectl patch configmap argocd-cm -n argocd --type merge \
  -p '{"data":{"accounts.backstage":"apiKey, login"}}'
kubectl patch configmap argocd-rbac-cm -n argocd --type merge --patch-file /dev/stdin <<'EOF'
data:
  policy.csv: |
    g, backstage, role:readonly
EOF
# Workshop-grade password "cloudbox123", pre-hashed (bcrypt) so this works
# offline without the argocd CLI. Must match gitops/components/backstage.
kubectl patch secret argocd-secret -n argocd --type merge --patch-file /dev/stdin <<'EOF'
stringData:
  accounts.backstage.password: $2a$10$25nwQLqr5OyQijChv7urwu0fPnSsJdWgMfwB0UX9aRvubyFrfwbwK
  accounts.backstage.passwordMtime: "2026-07-13T00:00:00Z"
EOF

info "Exposing the ArgoCD UI on NodePort ${NODEPORT_ARGOCD} (plain http for the lab)"
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge \
  -p '{"data":{"server.insecure":"true"}}'
kubectl patch service argocd-server -n argocd \
  -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":80,\"nodePort\":${NODEPORT_ARGOCD}}]}}"
# Restart so the server picks up server.insecure
kubectl -n argocd rollout restart deployment argocd-server >/dev/null

# --- 4. Wait for everything --------------------------------------------------------------
step "Waiting for Gitea and ArgoCD to become ready"
kubectl -n gitea rollout status deployment/gitea --timeout=300s
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

echo
ok "GitOps engine is running."
echo
echo "  Gitea:   ${GITEA_HOST_URL}  (${GITEA_ADMIN_USER} / ${GITEA_ADMIN_PASSWORD})"
echo "  ArgoCD:  ${ARGOCD_HOST_URL}  (user: admin)"
echo
info "ArgoCD admin password:"
echo "   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
echo
info "Next: ./scripts/seed-gitea.sh   # push this repo into your cloud"
