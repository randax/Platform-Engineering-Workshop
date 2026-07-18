#!/usr/bin/env bash
# =============================================================================
# kind-fallback.sh — plan B: kind cluster + Cilium
#
# If Talos-in-Docker won't run on your machine, this creates a kind cluster
# with the same shape: 1 control-plane + 1 worker, no default CNI, no
# kube-proxy, Cilium installed the same way, and the same NodePorts published
# on localhost. You lose the Talos content of module 1; every later module
# works identically.
#
# Usage:
#   ./scripts/kind-fallback.sh           # create
#   kind delete cluster --name cloudbox  # destroy
#
# The cloudbox-mirror registry (if running) is wired into both nodes via
# containerd hosts.toml files, same as the Talos path.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

need kind
need kubectl
need helm
need docker
docker_running || die "Docker daemon is not reachable. Start Docker and re-run."

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  die "A kind cluster '${CLUSTER_NAME}' already exists. Delete it first: kind delete cluster --name ${CLUSTER_NAME}"
fi

# --- 1. Create the kind cluster -------------------------------------------------
step "Creating kind cluster '${CLUSTER_NAME}' (Kubernetes from ${KIND_NODE_IMAGE%%@*})"
# disableDefaultCNI + kubeProxyMode:none — Cilium replaces both, exactly like
# the Talos path. NodePorts are published from the worker; Cilium's kube-proxy
# replacement makes them answer on every node.
kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}" --config=- <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  kubeProxyMode: "none"
nodes:
  - role: control-plane
  - role: worker
    extraPortMappings:
      - containerPort: ${NODEPORT_GITEA}
        hostPort: ${NODEPORT_GITEA}
      - containerPort: ${NODEPORT_ARGOCD}
        hostPort: ${NODEPORT_ARGOCD}
      - containerPort: ${NODEPORT_ZOT}
        hostPort: ${NODEPORT_ZOT}
      - containerPort: ${NODEPORT_PORTAL}
        hostPort: ${NODEPORT_PORTAL}
      - containerPort: ${NODEPORT_BACKSTAGE}
        hostPort: ${NODEPORT_BACKSTAGE}
      - containerPort: ${NODEPORT_RUSTFS_S3}
        hostPort: ${NODEPORT_RUSTFS_S3}
      - containerPort: ${NODEPORT_GRAFANA}
        hostPort: ${NODEPORT_GRAFANA}
      - containerPort: ${NODEPORT_KOURIER}
        hostPort: ${NODEPORT_KOURIER}
EOF

# --- 2. Wire up the image mirror (if present) --------------------------------------
if mirror_running; then
  # kind's containerd uses hosts.toml files (config_path is enabled by default).
  # On Linux the kind network gateway differs from the Talos one — detect it.
  if [[ "$(uname -s)" == "Darwin" ]] || is_wsl2; then
    MIRROR_ENDPOINT="http://host.docker.internal:${MIRROR_PORT}"
  else
    gw="$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
    MIRROR_ENDPOINT="http://${gw:-172.17.0.1}:${MIRROR_PORT}"
  fi
  [[ -n "${CLOUDBOX_MIRROR_HOST:-}" ]] && MIRROR_ENDPOINT="http://${CLOUDBOX_MIRROR_HOST}:${MIRROR_PORT}"

  step "Pointing node containerd mirrors at ${MIRROR_ENDPOINT}"
  registries=(docker.io ghcr.io registry.k8s.io quay.io gcr.io public.ecr.aws xpkg.crossplane.io docker.gitea.com)
  for node in "${CLUSTER_NAME}-control-plane" "${CLUSTER_NAME}-worker"; do
    for reg in "${registries[@]}"; do
      docker exec "${node}" mkdir -p "/etc/containerd/certs.d/${reg}"
      docker exec -i "${node}" tee "/etc/containerd/certs.d/${reg}/hosts.toml" >/dev/null <<EOF
server = "https://${reg}"

[host."${MIRROR_ENDPOINT}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
    done
  done
  ok "Mirror wired into both nodes (falls back to the real registries on a miss)"
else
  warn "cloudbox-mirror registry is not running — nodes will pull from the internet."
fi

# --- 3. Cilium ------------------------------------------------------------------------
step "Installing Cilium ${CILIUM_VERSION} (CNI + kube-proxy replacement)"
# Same install as the Talos path minus the Talos-specific values (no KubePrism,
# no cgroup/securityContext overrides — kind doesn't need them).
helm repo add cilium "${CILIUM_HELM_REPO}" --force-update >/dev/null
helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${CLUSTER_NAME}-control-plane" \
  --set k8sServicePort=6443

# --- 4. Wait for Ready -------------------------------------------------------------------
step "Waiting for nodes to become Ready (Cilium rollout)"
wait_rollout kube-system daemonset/cilium
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide

echo
ok "Fallback cluster '${CLUSTER_NAME}' is up (kubectl context: kind-${CLUSTER_NAME})."
info "Continue exactly like the Talos path:"
echo "   ./scripts/bootstrap-gitops.sh"
echo "   ./scripts/seed-gitea.sh"
