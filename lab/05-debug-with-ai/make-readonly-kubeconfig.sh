#!/usr/bin/env bash
# Create a READ-ONLY kubeconfig for pointing an AI agent at your cluster.
# The agent can look at everything (get/list/watch) and change nothing.
#   ./make-readonly-kubeconfig.sh [output-path]
set -euo pipefail

OUT="${1:-$PWD/ai-readonly.kubeconfig}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sourcing common.sh runs the workshop-context guard. This binds a read-everything
# ClusterRole to a ServiceAccount and mints a token for it — never on a cluster
# that is not the workshop's.
# shellcheck source=../common.sh
source "$DIR/../common.sh"

kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ai-observer
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ai-observer-readonly
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ai-observer-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ai-observer-readonly
subjects:
  - kind: ServiceAccount
    name: ai-observer
    namespace: default
EOF

TOKEN="$(kubectl -n default create token ai-observer --duration=4h)"
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: cloudbox
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA_DATA}
users:
  - name: ai-observer
    user:
      token: ${TOKEN}
contexts:
  - name: ai-observer@cloudbox
    context:
      cluster: cloudbox
      user: ai-observer
current-context: ai-observer@cloudbox
EOF
chmod 600 "$OUT"

echo "✅ read-only kubeconfig written to: $OUT (token valid 4h)"
echo
echo "Sanity check (should work):   KUBECONFIG=$OUT kubectl get pods -A"
echo "Sanity check (should FAIL):   KUBECONFIG=$OUT kubectl delete pod -n default anything"
echo
echo "Point your agent at it, e.g.:"
echo "  KUBECONFIG=$OUT claude   # or kubectl-ai, k8sgpt analyze, ..."
