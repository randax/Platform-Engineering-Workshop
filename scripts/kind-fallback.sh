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
# kind is NOT a substrate — there is no scripts/substrate/kind.sh and neither
# create-cluster.sh nor destroy-cluster.sh can build or tear this down. It IS a
# persisted IDENTITY: this script writes `kind` into ~/.cloudbox/substrate on a
# successful create and clears it on --delete, so that every helper keyed on
# that file (install.sh --check, the mirror architecture, the host gateway,
# lab 00) knows which machine it is looking at. Writing nothing there was worse
# in both directions: the lifeboat was graded as a Talos-in-Docker machine whose
# containers do not exist, and destroy-cluster.sh's "no answer means docker"
# fallback would remove the /etc/hosts block of a cluster that is still running.
#
#   ./scripts/kind-fallback.sh            # create
#   ./scripts/kind-fallback.sh --delete   # delete the cluster, remove the
#                                         # /etc/hosts block it wrote, and clear
#                                         # the identity
#
# No state file (a machine that took the lifeboat before this existed)? Say so
# for the session: CLOUDBOX_SUBSTRATE=kind ./scripts/install.sh --check
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
    echo "  --delete    delete that cluster, remove the ${CLOUDBOX_HOSTS_FILE} block and"
    echo "              clear the recorded identity"
    echo "              (destroy-cluster.sh cannot: kind is not one of the two substrates)"
    exit 0 ;;
  *) die "Unknown argument: ${1} (see --help)" ;;
esac

need kind
need kubectl

# --delete FIRST: it needs neither helm nor a reachable cluster, and it is the
# command someone reaches for when the create left a mess.
if [[ "${DELETE}" == "true" ]]; then
  # Read the identity BEFORE deleting anything: it decides whether the
  # /etc/hosts block is ours to remove.
  identity="$(substrate_current || true)"
  step "Deleting the kind fallback cluster '${CLUSTER_NAME}'"
  if kind_cluster_exists; then
    kind delete cluster --name "${CLUSTER_NAME}"
    ok "kind cluster '${CLUSTER_NAME}' deleted"
  else
    info "No kind cluster '${CLUSTER_NAME}' — nothing to delete."
  fi

  # The block is removed ONLY when this machine's recorded identity is 'kind'.
  # On 'docker' or 'tbx' it belongs to a cluster this script did not create and
  # may not touch: someone who runs --delete out of habit on a docker-substrate
  # machine would otherwise take out the hostnames of a cluster that is up.
  hosts_left="false"
  hosts_stray=""
  case "${identity}" in
    kind)
      # Same block, same remover as the docker substrate's destroy. Never fatal:
      # the cluster is already gone, and a declined sudo is a name-resolution
      # problem, not a teardown failure.
      remove_hosts_block || hosts_left="true"
      if [[ "${hosts_left}" == "true" ]]; then
        warn "Remove the remaining CloudBox lines from ${CLOUDBOX_HOSTS_FILE} by hand (see above)."
      else
        # The same scan destroy-cluster.sh runs, for the same reason: an
        # unmarked 127.0.0.1 line — a hand-pasted --print-hosts block whose
        # comments were deleted, a name appended to the localhost line —
        # survives every removal this script performs, by design. It keeps
        # resolving after the lifeboat is gone, and on a later tbx cluster it
        # OVERRIDES talos-box's resolver on a perfectly healthy machine.
        hosts_stray="$(hosts_loopback_lines)"
      fi
      rm -f "${CLOUDBOX_SUBSTRATE_FILE}"
      ok "Identity cleared (${CLOUDBOX_SUBSTRATE_FILE})"
      ;;
    "")
      warn "No identity recorded in ${CLOUDBOX_SUBSTRATE_FILE}, so the ${CLOUDBOX_HOSTS_FILE} block"
      warn "was left alone — this script only removes a block it can prove is the lifeboat's."
      warn "If those names were this cluster's: sudo \$EDITOR ${CLOUDBOX_HOSTS_FILE}   # delete the marked block"
      ;;
    *)
      warn "${CLOUDBOX_SUBSTRATE_FILE} says '${identity}', not 'kind' — the ${CLOUDBOX_HOSTS_FILE} block"
      warn "belongs to that cluster and was NOT touched. Tear it down with ./scripts/destroy-cluster.sh."
      ;;
  esac
  if [[ -n "${hosts_stray}" ]]; then
    warn "The CloudBox block is gone, but these lines in ${CLOUDBOX_HOSTS_FILE} still point"
    warn "CloudBox names at 127.0.0.1 (line: text) — they are OUTSIDE the markers, so this"
    warn "script does not touch them:"
    printf '   %s\n' "${hosts_stray}"
    warn "Nothing listens there now. Remove them by hand: sudo \$EDITOR ${CLOUDBOX_HOSTS_FILE}"
  fi
  info "The kubeconfig context kind-${CLUSTER_NAME} is removed by 'kind delete cluster'."
  exit 0
fi

need helm
need docker
docker_running || die "Docker daemon is not reachable. Start Docker and re-run."

if kind_cluster_exists; then
  die "A kind cluster '${CLUSTER_NAME}' already exists. Delete it first: ./scripts/kind-fallback.sh --delete"
fi

# --- 0. Preflight: is this machine free to take the lifeboat? -----------------
# The lifeboat had none, and it needs the same one the docker substrate has:
# everything below binds the same host ports, claims the same cluster name and
# writes the same /etc/hosts block. Running it over a live cluster produced two
# clusters, a fought-over port 80 and a hosts block whose owner nothing could
# name — on a machine reached by someone whose day has already gone wrong.
#
# `-aq`, not `-q`: stopped Talos containers are exactly as fatal as running
# ones, because ./scripts/create-cluster.sh refuses to create over them and
# `docker start` is the documented recovery.
if [[ -n "$(docker ps -aq --filter "label=talos.cluster.name=${CLUSTER_NAME}" 2>/dev/null)" ]]; then
  fail "A Talos-in-Docker cluster '${CLUSTER_NAME}' exists on this machine (running or stopped)."
  warn "The lifeboat would take its ports, its name and its ${CLOUDBOX_HOSTS_FILE} block."
  die "Tear it down first: ./scripts/destroy-cluster.sh"
fi
# The same three-way question substrate/docker.sh asks, and for the same reason:
# tbx VMs are invisible to `docker ps`, hold the cluster name and (through
# talos-box's resolver) the hostnames. A "cannot inspect" answer only blocks
# when this machine carries persisted traces of a tbx cluster — a half-installed
# tbx with no cluster ever created is the single most likely reason someone is
# reading this script at all, and dying there would make the lifeboat unreachable.
if have tbx && [[ "${CLOUDBOX_IGNORE_TBX:-}" != "1" ]]; then
  tbx_absent=0
  tbx_cluster_absent "${CLUSTER_NAME}" || tbx_absent=$?
  if [[ "${tbx_absent}" -eq 1 ]]; then
    fail "A '${CLUSTER_NAME}' cluster already exists on the tbx substrate — its VMs are running."
    die "Tear it down first: CLOUDBOX_SUBSTRATE=tbx ./scripts/destroy-cluster.sh"
  elif [[ "${tbx_absent}" -eq 2 ]] && tbx_local_evidence "${CLUSTER_NAME}"; then
    fail "tbx is installed but cannot be inspected, so whether a '${CLUSTER_NAME}' cluster"
    fail "already exists on the tbx substrate is unknown:"
    printf '   %s\n' "${TBX_CLUSTER_ABSENT_REASON}"
    warn "This machine HAS created a tbx cluster before, and if its VMs are running the"
    warn "lifeboat would be a second cluster of the same name."
    die "Fix tbx ('tbx doctor'), or set CLOUDBOX_IGNORE_TBX=1 to proceed anyway."
  fi
fi
# The ports this script is about to publish. Same list and same probe as
# install.sh --check, including port 80 — the privileged one that makes the
# hostnames work without a port, and the one whose holder is most often
# something else entirely. `kind create cluster` fails on a bound port AFTER
# creating containers, which is the wreck this refusal exists to avoid.
kind_ports=("${NODEPORT_GITEA}" "${NODEPORT_ARGOCD}" "${NODEPORT_ZOT}" \
            "${NODEPORT_PORTAL}" "${NODEPORT_BACKSTAGE}" "${NODEPORT_RUSTFS_S3}" \
            "${NODEPORT_GRAFANA}" "${NODEPORT_KOURIER}" "${NODEPORT_NATS}" 80)
ports_taken=()
for kind_port in "${kind_ports[@]}"; do
  port_in_use "${kind_port}" && ports_taken+=("${kind_port}")
done
if [[ "${#ports_taken[@]}" -gt 0 ]]; then
  fail "These host ports are already in use: ${ports_taken[*]}"
  for kind_port in "${ports_taken[@]}"; do
    if [[ "${kind_port}" == "80" ]]; then
      warn "  port 80 (the ingress; every *.${CLOUDBOX_DOMAIN} URL needs it):"
      port80_listeners
    else
      holder="$(port_listeners "${kind_port}")"
      [[ -n "${holder}" ]] && printf '   %s\n' "${holder}"
    fi
  done
  die "Free them and re-run — kind would create the cluster and then fail to publish them."
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

# The identity, the moment there is something to own it. Written HERE and not
# at the end for the same reason create-cluster.sh persists before its create:
# everything below this line can fail (a Cilium rollout that never converges, a
# Ctrl-C during the wait) and leave node containers, a published port 80 and a
# kubeconfig context behind — and the one command that cleans those up,
# `--delete`, decides what it may touch by reading this file.
substrate_persist kind
info "Recorded 'kind' in ${CLOUDBOX_SUBSTRATE_FILE} — install.sh --check, lab 00 and the"
info "image mirror all read it; ./scripts/kind-fallback.sh --delete clears it."

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
  # On Linux the kind network gateway differs from the Talos one, so it is
  # detected — by kind_network_gateway() in lib.sh, which is also what
  # cloudbox_host_gateway() answers with on this identity (kagent's Ollama host,
  # module 10). It was inlined here; the second caller is why it moved.
  MIRROR_ENDPOINT="http://$(kind_network_gateway):${MIRROR_PORT}"

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
info "Recorded identity: kind (${CLOUDBOX_SUBSTRATE_FILE}) — not a substrate, so"
info "./scripts/create-cluster.sh and ./scripts/destroy-cluster.sh both refuse here."
if [[ "${hosts_ok}" != "true" ]]; then
  warn "…but the ${CLOUDBOX_HOSTS_FILE} block was NOT written (see above), so every"
  warn "*.${CLOUDBOX_DOMAIN} URL will fail on a perfectly healthy cluster."
  warn "Fix it any time — the cluster keeps running: ./scripts/install.sh --write-hosts"
fi
info "Continue exactly like the Talos path — modules 02 onward are identical:"
echo "   ./scripts/bootstrap-gitops.sh"
echo "   ./scripts/seed-gitea.sh"
info "When you are done (destroy-cluster.sh refuses on this identity):"
echo "   ./scripts/kind-fallback.sh --delete   # cluster + ${CLOUDBOX_HOSTS_FILE} block + identity"
