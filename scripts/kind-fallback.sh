#!/usr/bin/env bash
# =============================================================================
# kind-fallback.sh — plan B: kind cluster + Cilium
#
# If neither substrate will run on your machine, this creates a kind cluster
# that meets the SAME CONTRACT the two real substrates meet, so every module
# from 02 onward is identical:
#
#   * 1 control-plane + 1 worker, no default CNI, no kube-proxy
#   * Cilium from the same vendored chart, with the SAME ingress values
#     (cilium_ingress_values in lib.sh) — so `ingressClassName: cilium` means
#     what gitops/ expects and every *.cloudbox.k8s.test hostname resolves to
#     the one shared ingress
#   * host port 80 -> the ingress NodePort, and the marked /etc/hosts block,
#     exactly as the docker substrate does it
#   * the nine workshop NodePorts still published, for the Codespaces Ports tab
#   * the cloudbox-mirror registry wired into both nodes via containerd
#     hosts.toml, same as the Talos path
#
# You lose the Talos content of module 1 — that is the whole cost.
#
# kind is NOT a substrate. It writes no ~/.cloudbox/substrate, so
# destroy-cluster.sh (which reads that file and knows only tbx and docker) will
# never find this cluster. Tear it down with THIS script:
#
#   ./scripts/kind-fallback.sh            # create
#   ./scripts/kind-fallback.sh --delete   # delete the cluster AND remove the
#                                         # /etc/hosts block it wrote
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

DELETE="false"
case "${1:-}" in
  "") ;;
  --delete) DELETE="true" ;;
  -h|--help)
    echo "Usage: $0 [--delete]"
    echo "  (no flags)  create the kind fallback cluster (Cilium, ingress on host port 80,"
    echo "              the marked ${CLOUDBOX_HOSTS_FILE} block)"
    echo "  --delete    delete that cluster and remove the ${CLOUDBOX_HOSTS_FILE} block"
    echo "              (destroy-cluster.sh cannot: kind is not one of the two substrates)"
    exit 0 ;;
  *) die "Unknown argument: ${1} (see --help)" ;;
esac

need kind
need kubectl

# --delete FIRST: it needs neither helm nor a reachable cluster, and it is the
# command someone reaches for when the create left a mess.
if [[ "${DELETE}" == "true" ]]; then
  step "Deleting the kind fallback cluster '${CLUSTER_NAME}'"
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    ok "kind cluster '${CLUSTER_NAME}' deleted"
  else
    info "No kind cluster '${CLUSTER_NAME}' — nothing to delete."
  fi
  # Same block, same remover as the docker substrate's destroy. Never fatal:
  # the cluster is already gone, and a declined sudo is a name-resolution
  # problem, not a teardown failure.
  hosts_left="false"
  remove_hosts_block || hosts_left="true"
  if [[ "${hosts_left}" == "true" ]]; then
    warn "Remove the remaining CloudBox lines from ${CLOUDBOX_HOSTS_FILE} by hand (see above)."
  fi
  info "The kubeconfig context kind-${CLUSTER_NAME} is removed by 'kind delete cluster'."
  exit 0
fi

need helm
need docker
docker_running || die "Docker daemon is not reachable. Start Docker and re-run."

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  die "A kind cluster '${CLUSTER_NAME}' already exists. Delete it first: ./scripts/kind-fallback.sh --delete"
fi

# --- 1. Create the kind cluster -------------------------------------------------
step "Creating kind cluster '${CLUSTER_NAME}' (Kubernetes from ${KIND_NODE_IMAGE%%@*})"
# disableDefaultCNI + kubeProxyMode:none — Cilium replaces both, exactly like
# the Talos path. Ports are published from the worker; Cilium's kube-proxy
# replacement makes them answer on every node.
#
# Host 80 -> containerPort NODEPORT_INGRESS is the mapping that makes this a
# lifeboat rather than a raft. Every workshop URL is now a hostname served by
# the shared Cilium ingress — seed-gitea.sh pushes to gitea.cloudbox.k8s.test,
# and the labs from module 02 on are written against those names. Without this
# line (and the /etc/hosts block below) the fallback published nine NodePorts
# and could not answer a single hostname: module 02 failed on its first push.
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
      - containerPort: ${NODEPORT_INGRESS}
        hostPort: 80
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
      - containerPort: ${NODEPORT_NATS}
        hostPort: ${NODEPORT_NATS}
      - containerPort: ${NODEPORT_KOURIER}
        hostPort: ${NODEPORT_KOURIER}
EOF

# NOT guarded at the top — like create-cluster.sh, this script is what creates
# the workshop context. `kind create cluster` selects kind-${CLUSTER_NAME} and
# publishes the API on 127.0.0.1, so from here the guard is a post-condition,
# asserted before the Cilium helm install and the kubectl calls below.
require_workshop_context
# Same as the Talos path: `kind create cluster` writes to KUBECONFIG, which
# mise.toml pins to ~/.kube/cloudbox.conf for this repo (and which is your
# ordinary ~/.kube/config when mise is not activated).
info "kubeconfig: $(kubeconfig_in_use)"

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
step "Installing Cilium ${CILIUM_VERSION} (CNI + kube-proxy replacement + ingress)"
# Same install as the Talos path minus the Talos-specific values (no KubePrism,
# no cgroup/securityContext overrides — kind doesn't need them), and from the
# same VENDORED chart. This used to `helm repo add cilium ${CILIUM_HELM_REPO}`
# and pull cilium/cilium from the internet, which is the one thing the lifeboat
# cannot afford: it is reached by someone whose cluster already failed, on venue
# WiFi, and it fails AFTER creating the kind cluster — leaving a CNI-less
# wreck whose kind-cloudbox context the workshop guard happily accepts. Measured
# on the first run this script has ever had:
#
#   ==> Installing Cilium 1.20.0 (CNI + kube-proxy replacement)
#   Error: looks like "https://helm.cilium.io" is not a valid chart repository or
#   cannot be reached: Get "https://helm.cilium.io/index.yaml": context deadline
#   exceeded                                                            exit 1
#
# create-cluster.sh has vendored the chart since the beginning, for this reason,
# in a comment that says so. Re-vendor both from CILIUM_HELM_REPO when bumping;
# check-consistency.sh fails if the tarball for CILIUM_VERSION is missing.
#
# The INGRESS values are not duplicated here: cilium_ingress_values (lib.sh) is
# the single source create-cluster.sh reads too, asked for the `nodeport` shape
# — the same one the docker substrate uses, reached through the host port 80
# mapping above. Duplicating them is how "the lifeboat serves the identical
# labs" quietly stops being true.
#
# --server-side=false pins helm 3's client-side apply. helm 4 defaults this to
# "auto", which for a FRESH release (every workshop cluster) resolves to
# server-side apply — a behaviour change on the one path `helm template`
# cannot exercise. Nothing here needs server-side; keeping the proven path
# makes this a same-behaviour-newer-binary bump. Drop the flag once a full
# bootstrap-test has been green with it removed.
cilium_values=(
  --set ipam.mode=kubernetes
  --set kubeProxyReplacement=true
  --set k8sServiceHost="${CLUSTER_NAME}-control-plane"
  --set k8sServicePort=6443
)
while IFS= read -r cilium_flag; do
  cilium_values+=("${cilium_flag}")
done < <(cilium_ingress_values nodeport)
helm upgrade --install cilium \
  --server-side=false \
  "${SCRIPT_DIR}/manifests/cilium-${CILIUM_VERSION}.tgz" \
  --namespace kube-system \
  "${cilium_values[@]}"

# --- 4. Wait for Ready -------------------------------------------------------------------
step "Waiting for nodes to become Ready (Cilium rollout)"
wait_rollout kube-system daemonset/cilium
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide

# --- 5. Hostnames -------------------------------------------------------------------
# LAST, and non-fatal — the same order and the same reason as create-cluster.sh:
# this is the one step an attendee can REFUSE, and a cluster that is up must not
# be thrown away over name resolution. Nothing above needs the names.
hosts_ok="true"
write_hosts_block || hosts_ok="false"

echo
ok "Fallback cluster '${CLUSTER_NAME}' is up (kubectl context: kind-${CLUSTER_NAME})."
if [[ "${hosts_ok}" != "true" ]]; then
  warn "…but the ${CLOUDBOX_HOSTS_FILE} block was NOT written (see above), so every"
  warn "*.${CLOUDBOX_DOMAIN} URL will fail on a perfectly healthy cluster."
  warn "Fix it any time — the cluster keeps running: ./scripts/install.sh --write-hosts"
fi
info "Continue exactly like the Talos path — modules 02 onward are identical:"
echo "   ./scripts/bootstrap-gitops.sh"
echo "   ./scripts/seed-gitea.sh"
info "When you are done (destroy-cluster.sh does not know about kind):"
echo "   ./scripts/kind-fallback.sh --delete   # cluster + ${CLOUDBOX_HOSTS_FILE} block"
