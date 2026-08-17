#!/usr/bin/env bash
# =============================================================================
# create-cluster.sh — module 1: create the CloudBox Talos cluster
#
# What it does:
#   1. talosctl cluster create docker — Talos v1.13.8, 1 controlplane +
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

# No containers, but a leftover talosconfig context named ${CLUSTER_NAME} makes
# `talosctl cluster create` rename the NEW context to '${CLUSTER_NAME}-1' —
# after which every `talosctl --context ${CLUSTER_NAME}` below dials the
# endpoint of a cluster that no longer exists and this script fails at
# "Merging kubeconfig". destroy-cluster.sh now clears it; this catches a stale
# context left by an older destroy, a hand-run `talosctl cluster destroy`, or a
# create that died halfway.
talos_contexts() { # -> one context name per line, '*' marker stripped
  talosctl config contexts 2>/dev/null | awk 'NR > 1 { print ($1 == "*") ? $2 : $1 }'
}
if talos_contexts | grep -qx "${CLUSTER_NAME}"; then
  warn "Removing a stale talosconfig context '${CLUSTER_NAME}' (no such cluster is running)"
  other="$(talos_contexts | grep -vx "${CLUSTER_NAME}" | head -1)"
  if [[ -n "${other}" ]]; then
    # `talosctl config remove` refuses to remove the SELECTED context (and
    # exits 0 anyway), so select something else first.
    talosctl config context "${other}" >/dev/null 2>&1 || true
    talosctl config remove "${CLUSTER_NAME}" --noconfirm >/dev/null 2>&1 || true
  else
    rm -f "${TALOSCONFIG:-${HOME}/.talos/config}"
  fi
  talos_contexts | grep -qx "${CLUSTER_NAME}" \
    && die "Could not remove the stale talosconfig context '${CLUSTER_NAME}' — remove it by hand (talosctl config remove ${CLUSTER_NAME}) and re-run."
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
  # Every cloud region had to start somewhere.
  nodeLabels:
    cloudbox.io/region: eu-laptop-1
    cloudbox.io/zone: under-desk-a
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
# skipFallback:false means nodes fall back to the real registry on a MISS, so a
# stale or incomplete mirror just costs bandwidth. One caveat: tag-pinned
# mirror content is arch-specific (cloudbox-init.sh copies with --platform),
# and a mirror populated for a different architecture still answers — no miss,
# no fallback, exec-format crashloops instead. install.sh --check catches that
# case by verifying every tag pin's architecture before the workshop.
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
# CPU caps: talosctl defaults both to 2.0, which caps the whole cluster at 4
# cores regardless of the host — enough for modules 00-05, not for the module 10
# end state (21 apps, ~125 containers). Scale with the daemon's CPU count and
# floor at talosctl's own default, so the published MIN_CPUS=4 machine gets
# exactly what it got before and a bigger laptop actually gets used.
# See TALOS_CPU_SHARE_* in versions.env and docs/HAZARDS.md.
host_cpus="$(docker info -f '{{.NCPU}}' 2>/dev/null || echo 0)"
cpu_share() { # <fraction> -> cores, floored at TALOS_CPU_FLOOR, integer
  awk -v n="${host_cpus}" -v f="$1" -v floor="${TALOS_CPU_FLOOR}" \
    'BEGIN { c = int(n * f + 0.5); if (c < floor) c = floor; printf "%d", c }'
}
CPUS_CONTROLPLANE="$(cpu_share "${TALOS_CPU_SHARE_CONTROLPLANE}")"
CPUS_WORKER="$(cpu_share "${TALOS_CPU_SHARE_WORKER}")"
info "Node CPU caps: ${CPUS_CONTROLPLANE} control-plane / ${CPUS_WORKER} worker (host has ${host_cpus})"

# kube-proxy replacement makes every NodePort answer on every node.
talosctl cluster create docker \
  --name "${CLUSTER_NAME}" \
  --image "${TALOS_IMAGE}" \
  --kubernetes-version "${KUBERNETES_VERSION}" \
  --workers 1 \
  --memory-controlplanes "${TALOS_MEMORY_CONTROLPLANE}" \
  --memory-workers "${TALOS_MEMORY_WORKER}" \
  --cpus-controlplanes "${CPUS_CONTROLPLANE}" \
  --cpus-workers "${CPUS_WORKER}" \
  --subnet "${TALOS_SUBNET}" \
  --exposed-ports "${NODEPORT_GITEA}:${NODEPORT_GITEA}/tcp,${NODEPORT_ARGOCD}:${NODEPORT_ARGOCD}/tcp,${NODEPORT_ZOT}:${NODEPORT_ZOT}/tcp,${NODEPORT_PORTAL}:${NODEPORT_PORTAL}/tcp,${NODEPORT_BACKSTAGE}:${NODEPORT_BACKSTAGE}/tcp,${NODEPORT_RUSTFS_S3}:${NODEPORT_RUSTFS_S3}/tcp,${NODEPORT_GRAFANA}:${NODEPORT_GRAFANA}/tcp,${NODEPORT_KOURIER}:${NODEPORT_KOURIER}/tcp,${NODEPORT_NATS}:${NODEPORT_NATS}/tcp" \
  "${patches[@]}"

# --- 2. kubeconfig ------------------------------------------------------------------
step "Merging kubeconfig"
# The controlplane always gets the first host address of TALOS_SUBNET (.2 —
# .1 is the gateway). Set it as the context's default node so every later
# talosctl command (yours included) works without a -n flag; on a fresh
# machine `talosctl kubeconfig` fails without this (found by rehearsal-in-CI).
TALOS_CP_IP="${TALOS_SUBNET_GATEWAY%.*}.2"
talosctl --context "${CLUSTER_NAME}" config node "${TALOS_CP_IP}"
talosctl --context "${CLUSTER_NAME}" kubeconfig --force
# `talosctl kubeconfig` writes the server address from the machine config's
# cluster.controlPlane.endpoint, which for a docker cluster is the node's
# in-network address (https://10.5.0.2:6443). That is reachable from the host
# ONLY on native Linux. On macOS and Windows — Docker Desktop, OrbStack,
# Colima — the host cannot route into the Talos docker network, so the line
# above silently replaces the working kubeconfig `talosctl cluster create` had
# just merged, and every kubectl call from here on hangs on TCP connect.
# Point it at the port the controlplane container publishes instead: talosctl
# puts 127.0.0.1 in the API server's certSANs for exactly this purpose, so the
# address is valid on every platform (Linux included).
CP_CONTAINER="$(docker ps -q \
  --filter "label=talos.cluster.name=${CLUSTER_NAME}" \
  --filter "label=talos.type=controlplane" | head -1)"
API_PORT="$(docker port "${CP_CONTAINER}" 6443/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')"
if [[ -n "${API_PORT}" ]]; then
  kubectl config set-cluster "${CLUSTER_NAME}" \
    --server="https://127.0.0.1:${API_PORT}" >/dev/null
  info "Kubernetes API: https://127.0.0.1:${API_PORT} (published by the controlplane container)"
else
  warn "Could not read the published API port from the controlplane container —"
  warn "leaving the kubeconfig as talosctl wrote it (fine on native Linux)."
fi
kubectl config use-context "admin@${CLUSTER_NAME}" >/dev/null
ok "kubectl context: admin@${CLUSTER_NAME}"

step "Waiting for the Kubernetes API"
# --request-timeout is load-bearing: without it kubectl blocks on the OS TCP
# connect timeout (~75s on macOS) per attempt, so an unreachable API server
# turned this "2 minutes" into over an hour of apparent hang instead of a
# failure with the message below.
for _ in $(seq 1 60); do
  kubectl --request-timeout=5s get nodes >/dev/null 2>&1 && break
  sleep 2
done
kubectl --request-timeout=5s get nodes >/dev/null 2>&1 \
  || die "Kubernetes API did not come up within 2 minutes"
ok "API server is answering (nodes are NotReady until Cilium arrives — expected)"

# --- 3. Cilium ------------------------------------------------------------------------
step "Installing Cilium ${CILIUM_VERSION} (CNI + kube-proxy replacement)"
# Chart is vendored into scripts/manifests/ (re-vendor from CILIUM_HELM_REPO
# when bumping) so this needs no internet at the venue — principle 2.
# Values from the official Talos Cilium guide:
# https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium
# k8sServiceHost=localhost:7445 is KubePrism, Talos' local API server balancer.
# --server-side=false pins helm 3's client-side apply. helm 4 defaults this to
# "auto", which for a FRESH release (every workshop cluster) resolves to
# server-side apply — a behaviour change on the one path `helm template`
# cannot exercise. Nothing here needs server-side; keeping the proven path
# makes this a same-behaviour-newer-binary bump. Drop the flag once a full
# bootstrap-test has been green with it removed.
helm upgrade --install cilium \
  --server-side=false \
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
wait_rollout kube-system daemonset/cilium
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide

echo
ok "Cluster '${CLUSTER_NAME}' is up — you now own a cloud. ☁️"
info "Next steps:"
echo "   ./scripts/bootstrap-gitops.sh   # module 2: Gitea + ArgoCD"
echo "   ./scripts/seed-gitea.sh         # module 2: push this repo to your cloud"
info "Useful:"
echo "   talosctl --context ${CLUSTER_NAME} dashboard   # Talos node dashboard"
echo "   ./scripts/destroy-cluster.sh                          # tear it all down"
