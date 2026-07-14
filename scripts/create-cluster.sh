#!/usr/bin/env bash
# =============================================================================
# create-cluster.sh — module 1: create the CloudBox Talos cluster
#
# What it does:
#   1. talosctl cluster create docker — Talos v1.13.6, 1 controlplane +
#      1 worker, raised memory limits, CNI and kube-proxy disabled
#      (Cilium replaces both), workshop NodePorts published on localhost
#   2. Points the nodes' registry mirrors at the local cloudbox-mirror
#      registry (if it is running), with fallback to the real registries
#   3. Installs Cilium via Helm with the values from the official Talos guide
#   4. Waits for both nodes to become Ready and prints next steps
#
# Usage:
#   ./scripts/create-cluster.sh
#
# Environment overrides:
#   CLOUDBOX_MIRROR_HOST  address where node containers reach the mirror
#                         (default: host.docker.internal on macOS/WSL2,
#                          the Docker network gateway 10.5.0.1 on Linux)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

need talosctl
need kubectl
need helm
need docker
docker_running || die "Docker daemon is not reachable. Start Docker and re-run."

# Talos labels every node container with talos.cluster.name=<cluster>
if [[ -n "$(docker ps -aq --filter "label=talos.cluster.name=${CLUSTER_NAME}")" ]]; then
  die "A '${CLUSTER_NAME}' cluster already exists. Run ./scripts/destroy-cluster.sh first."
fi

# --- Machine config patches -----------------------------------------------------
# Disable the default CNI (flannel) and kube-proxy: Cilium replaces both.
# This is why Talos >= v1.13 is required — v1.12 hangs on cni:none (talos#12885).
CNI_PATCH="$(cat <<'EOF'
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
machine:
  kubelet:
    extraMounts:
      # local-path-provisioner writes PV data here; without this bind mount
      # every PVC on Talos stays Pending (kubelet cannot reach the host path).
      - destination: /var/local-path-provisioner
        type: bind
        source: /var/local-path-provisioner
        options: [bind, rshared, rw]
EOF
)"

patches=(--config-patch "${CNI_PATCH}")

# Registry mirrors: only wired up when the cloudbox-mirror registry is running.
# skipFallback:false means nodes fall back to the real registry on a miss, so a
# stale mirror can never break the cluster — it just costs bandwidth.
if mirror_running; then
  MIRROR_ENDPOINT="$(mirror_host_endpoint)"
  info "Image mirror detected — nodes will pull via ${MIRROR_ENDPOINT}"
  MIRROR_PATCH="$(cat <<EOF
machine:
  registries:
    mirrors:
      docker.io:
        endpoints:
          - ${MIRROR_ENDPOINT}
        skipFallback: false
      ghcr.io:
        endpoints:
          - ${MIRROR_ENDPOINT}
        skipFallback: false
      registry.k8s.io:
        endpoints:
          - ${MIRROR_ENDPOINT}
        skipFallback: false
      quay.io:
        endpoints:
          - ${MIRROR_ENDPOINT}
        skipFallback: false
      gcr.io:
        endpoints:
          - ${MIRROR_ENDPOINT}
        skipFallback: false
      public.ecr.aws:
        endpoints:
          - ${MIRROR_ENDPOINT}
        skipFallback: false
      xpkg.crossplane.io:
        endpoints:
          - ${MIRROR_ENDPOINT}
        skipFallback: false
      docker.gitea.com:
        endpoints:
          - ${MIRROR_ENDPOINT}
        skipFallback: false
EOF
)"
  patches+=(--config-patch "${MIRROR_PATCH}")
else
  warn "cloudbox-mirror registry is not running — nodes will pull from the internet."
  warn "Fine at home; at the venue run ./scripts/cloudbox-init.sh first."
fi

# --- 1. Create the cluster --------------------------------------------------------
step "Creating Talos cluster '${CLUSTER_NAME}' (Talos ${TALOS_VERSION}, Kubernetes ${KUBERNETES_VERSION})"
info "1 controlplane (${TALOS_MEMORY_CONTROLPLANE} MB) + 1 worker (${TALOS_MEMORY_WORKER} MB)"

# NodePorts are published on the controlplane container; Cilium's
# kube-proxy replacement makes every NodePort answer on every node.
talosctl cluster create docker \
  --name "${CLUSTER_NAME}" \
  --image "${TALOS_IMAGE}" \
  --kubernetes-version "${KUBERNETES_VERSION}" \
  --workers 1 \
  --memory-controlplanes "${TALOS_MEMORY_CONTROLPLANE}" \
  --memory-workers "${TALOS_MEMORY_WORKER}" \
  --subnet "${TALOS_SUBNET}" \
  --exposed-ports "${NODEPORT_GITEA}:${NODEPORT_GITEA}/tcp,${NODEPORT_ARGOCD}:${NODEPORT_ARGOCD}/tcp,${NODEPORT_ZOT}:${NODEPORT_ZOT}/tcp,${NODEPORT_PORTAL}:${NODEPORT_PORTAL}/tcp,${NODEPORT_BACKSTAGE}:${NODEPORT_BACKSTAGE}/tcp,${NODEPORT_RUSTFS_S3}:${NODEPORT_RUSTFS_S3}/tcp,${NODEPORT_KOURIER}:${NODEPORT_KOURIER}/tcp" \
  "${patches[@]}"

# --- 2. kubeconfig ------------------------------------------------------------------
step "Merging kubeconfig"
talosctl --context "${CLUSTER_NAME}" kubeconfig --force
kubectl config use-context "admin@${CLUSTER_NAME}" >/dev/null
ok "kubectl context: admin@${CLUSTER_NAME}"

step "Waiting for the Kubernetes API"
for _ in $(seq 1 60); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 2
done
kubectl get nodes >/dev/null 2>&1 || die "Kubernetes API did not come up within 2 minutes"
ok "API server is answering (nodes are NotReady until Cilium arrives — expected)"

# --- 3. Cilium ------------------------------------------------------------------------
step "Installing Cilium ${CILIUM_VERSION} (CNI + kube-proxy replacement)"
# Chart is vendored into scripts/manifests/ (re-vendor from CILIUM_HELM_REPO
# when bumping) so this needs no internet at the venue — principle 2.
# Values from the official Talos Cilium guide:
# https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium
# k8sServiceHost=localhost:7445 is KubePrism, Talos' local API server balancer.
helm upgrade --install cilium \
  "${SCRIPT_DIR}/manifests/cilium-${CILIUM_VERSION}.tgz" \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=localhost \
  --set k8sServicePort=7445 \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"

# --- 4. Wait for Ready -------------------------------------------------------------------
step "Waiting for nodes to become Ready (Cilium rollout)"
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide

echo
ok "Cluster '${CLUSTER_NAME}' is up — you now own a cloud. ☁️"
info "Next steps:"
echo "   ./scripts/bootstrap-gitops.sh   # module 2: Gitea + ArgoCD"
echo "   ./scripts/seed-gitea.sh         # module 2: push this repo to your cloud"
info "Useful:"
echo "   talosctl --context ${CLUSTER_NAME} -n 10.5.0.2 dashboard   # Talos node dashboard"
echo "   ./scripts/destroy-cluster.sh                          # tear it all down"
