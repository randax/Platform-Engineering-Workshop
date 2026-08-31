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
# The same override works for `--delete`, but there it is honoured only against
# KIND-SPECIFIC proof — kind must list the cluster, or Docker must still hold
# containers labelled io.x-k8s.kind.cluster=<name>. The /etc/hosts block is not
# proof: the docker substrate writes the identical block. An environment
# variable is a claim, and this script will not delete an /etc/hosts block it
# cannot show is its own.
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

# --delete FIRST: it needs neither helm nor a reachable cluster, and it is the
# command someone reaches for when the create left a mess. It also needs neither
# `kind` nor `kubectl` — those are asserted on the CREATE path below. --delete
# asks DOCKER for the node containers (kind_container_ids in lib.sh), which is
# the fact; the CLI is only the tool that removes them, and an attendee who
# uninstalled kind still has an /etc/hosts block and an identity record to clean
# up. Requiring the binary here made the one recovery command refuse to start on
# the machines that most needed it.
if [[ "${DELETE}" == "true" ]]; then
  # Every question below — does the cluster exist, are its containers gone, is
  # the override provable — is asked of the Docker daemon. With the daemon down
  # all of them answer "no", and this script would then report a deleted cluster,
  # remove the /etc/hosts block of a lifeboat that is merely stopped, and clear
  # the identity that says whose block it was. Same refusal, same wording as
  # substrate/docker.sh, before any of that.
  need docker
  docker_running || die "Docker daemon is not reachable. Start Docker and re-run."
  # A record that exists and cannot be read is not an absent record (lib.sh) —
  # and "absent" is exactly what sends this arm down the CLOUDBOX_SUBSTRATE
  # branch below and leaves an unowned block behind.
  assert_identity_readable
  # Read the identity BEFORE deleting anything: it decides whether the
  # /etc/hosts block is ours to remove.
  identity="$(substrate_current || true)"
  # No record at all, but the session was told CLOUDBOX_SUBSTRATE=kind — the
  # documented "lost state" recipe. An override is a claim, not a record, so it
  # is honoured only against PROOF that a lifeboat is what this machine has, and
  # the proof must be KIND-SPECIFIC: kind lists the cluster, or Docker holds
  # containers labelled io.x-k8s.kind.cluster=${CLUSTER_NAME}. The marked
  # /etc/hosts block is NOT proof — the docker substrate writes the identical
  # block, so a machine whose Talos cluster is up and whose identity record was
  # lost would have had its live block deleted by an environment variable, which
  # is the exact failure this branch exists to prevent. Asked BEFORE the delete
  # below, because both proofs are about to be destroyed by it.
  if [[ -z "${identity}" && "${CLOUDBOX_SUBSTRATE:-}" == "kind" ]]; then
    kind_proof=""
    if kind_cluster_exists; then
      kind_proof="kind lists a '${CLUSTER_NAME}' cluster"
    elif [[ -n "$(kind_container_ids)" ]]; then
      kind_proof="Docker holds containers labelled io.x-k8s.kind.cluster=${CLUSTER_NAME}"
    fi
    if [[ -n "${kind_proof}" ]]; then
      identity="kind"
      info "No identity recorded, but CLOUDBOX_SUBSTRATE=kind and ${kind_proof} — treating this as the lifeboat."
      # Written down NOW, while the proof is still standing. Everything below
      # can stop half-way (a declined sudo is the ordinary case), and a retry
      # then re-asks for the proof that this run has just deleted — so without
      # this the second `--delete` falls into the "no identity recorded" arm and
      # leaves the block forever. Recording it also means the retry needs no
      # environment variable at all.
      substrate_persist kind
      info "Recorded 'kind' in ${CLOUDBOX_SUBSTRATE_FILE} so a retry needs no CLOUDBOX_SUBSTRATE."
    else
      warn "CLOUDBOX_SUBSTRATE=kind, but nothing on this machine proves it: kind lists no"
      warn "'${CLUSTER_NAME}' cluster and Docker holds no containers labelled"
      warn "io.x-k8s.kind.cluster=${CLUSTER_NAME}."
      warn "The override is not taken as ownership — nothing here will be removed."
      warn "(The ${CLOUDBOX_HOSTS_FILE} block is deliberately not evidence: the docker"
      warn "substrate writes the identical block, and it may belong to a live cluster.)"
    fi
  fi
  step "Deleting the kind fallback cluster '${CLUSTER_NAME}'"
  # Whether the cluster is GONE when this is over, which is half of what clearing
  # the identity requires below. A delete that fails leaves a cluster whose only
  # cleanup command needs the identity to know the block is its own.
  #
  # "Gone" is proven against DOCKER, not against `kind get clusters`: the
  # containers are the thing that holds the ports, the name and the cluster, and
  # they are askable without the kind CLI. That is what lets this arm run at all
  # on a machine where kind was uninstalled after the lifeboat was created.
  cluster_gone="false"
  if kind_cluster_exists || [[ -n "$(kind_container_ids)" ]]; then
    if ! have kind; then
      fail "A kind lifeboat '${CLUSTER_NAME}' is on this machine (containers labelled io.x-k8s.kind.cluster=${CLUSTER_NAME}), but the 'kind' binary is not on PATH."
      warn "Nothing else here can remove those containers safely — kind owns the network,"
      warn "the kubeconfig context and the node labels."
      warn "Reinstall kind (./scripts/dev-setup.sh pins it) and re-run: ./scripts/kind-fallback.sh --delete"
    elif kind delete cluster --name "${CLUSTER_NAME}"; then
      # `kind delete cluster` exits 0 whether or not it found anything, so the
      # containers are asked again rather than trusted.
      if [[ -z "$(kind_container_ids)" ]]; then
        ok "kind cluster '${CLUSTER_NAME}' deleted"
        cluster_gone="true"
      else
        fail "'kind delete cluster --name ${CLUSTER_NAME}' reported success, but containers labelled io.x-k8s.kind.cluster=${CLUSTER_NAME} are still here."
        warn "Inspect them: docker ps -a --filter label=io.x-k8s.kind.cluster=${CLUSTER_NAME}"
      fi
    else
      fail "'kind delete cluster --name ${CLUSTER_NAME}' failed (above)."
    fi
  else
    info "No kind cluster '${CLUSTER_NAME}' and no containers labelled io.x-k8s.kind.cluster=${CLUSTER_NAME} — nothing to delete."
    cluster_gone="true"
  fi

  # The block is removed ONLY when this machine's recorded identity is 'kind'.
  # On 'docker' or 'tbx' it belongs to a cluster this script did not create and
  # may not touch: someone who runs --delete out of habit on a docker-substrate
  # machine would otherwise take out the hostnames of a cluster that is up.
  hosts_left="false"
  hosts_stray=""
  case "${identity}" in
    kind)
      if [[ "${cluster_gone}" != "true" ]]; then
        # The cluster is STILL THERE. Those hostnames are the only way to reach
        # it, and removing the block here would take name resolution away from a
        # running lifeboat while leaving every container in place — the worst of
        # both states, and reached by the ordinary failure above (a
        # `kind delete` that errored, or a machine whose kind binary is gone).
        hosts_left="true"
        warn "The ${CLOUDBOX_HOSTS_FILE} block was NOT touched: the cluster is still here (see"
        warn "above), and those names are how you reach it. Fix the delete and re-run."
      else
        # Same block, same remover as the docker substrate's destroy. Never
        # fatal here: the cluster is already gone, and a declined sudo is a
        # name-resolution problem, not a teardown failure.
        # 0 from remove_hosts_block means "removed, or proven not there"; 1
        # means "still there, or cannot tell" (a declined sudo, an unpaired
        # block, an unreadable file). That distinction decides the identity
        # below, and this script's exit status.
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
      fi
      # The identity goes ONLY when there is nothing left that needs it. It is
      # the single thing that lets a RETRY prove the /etc/hosts block is the
      # lifeboat's — clear it while the block (or the cluster) is still there and
      # the next `--delete` falls into the "no identity recorded" arm and leaves
      # the block alone forever, with no command left that will touch it.
      # A declined sudo password is the ordinary way this happens.
      if [[ "${cluster_gone}" == "true" && "${hosts_left}" != "true" ]]; then
        rm -f "${CLOUDBOX_SUBSTRATE_FILE}"
        ok "Identity cleared (${CLOUDBOX_SUBSTRATE_FILE})"
      else
        warn "KEEPING the recorded identity in ${CLOUDBOX_SUBSTRATE_FILE} — the teardown is not"
        warn "finished, and that file is what proves the ${CLOUDBOX_HOSTS_FILE} block is this"
        warn "cluster's to remove. Fix what failed above and re-run: ./scripts/kind-fallback.sh --delete"
      fi
      ;;
    "")
      warn "No identity recorded in ${CLOUDBOX_SUBSTRATE_FILE}, so the ${CLOUDBOX_HOSTS_FILE} block"
      warn "was left alone — this script only removes a block it can prove is the lifeboat's."
      warn "If this machine took the lifeboat before the identity file existed, say so and"
      warn "re-run — the claim is honoured once kind lists the cluster, or Docker still holds"
      warn "containers labelled io.x-k8s.kind.cluster=${CLUSTER_NAME}:"
      warn "  CLOUDBOX_SUBSTRATE=kind ./scripts/kind-fallback.sh --delete"
      warn "Once both are gone there is nothing left to prove ownership with, and the block"
      warn "goes by hand: sudo \$EDITOR ${CLOUDBOX_HOSTS_FILE}   # delete the marked block"
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
  # The exit status is the teardown's verdict, not "the script ran". It used to
  # be an unconditional 0, so `./scripts/kind-fallback.sh --delete && …` chained
  # straight on after a failed delete or a declined sudo, and CI could not tell
  # a finished teardown from a half-finished one. Anything left — the cluster
  # still here, or the block still in ${CLOUDBOX_HOSTS_FILE} — is a 1.
  if [[ "${cluster_gone}" != "true" || "${hosts_left}" == "true" ]]; then
    fail "The lifeboat teardown did not finish (see above). Re-run once you have fixed it:"
    warn "  ./scripts/kind-fallback.sh --delete"
    exit 1
  fi
  exit 0
fi

need kind
need kubectl

need helm
need docker
docker_running || die "Docker daemon is not reachable. Start Docker and re-run."

# BEFORE anything is created or written: this machine must not already BE
# something else. The preflight below asks docker and tbx what is running, which
# is the right question for a live cluster and the wrong one for a machine whose
# tbx binary has since been uninstalled, or whose docker daemon has been swapped
# — in both cases the record is the only thing that still knows, and persisting
# `kind` over it is unrecoverable. require_identity_match (lib.sh) dies here with
# the teardown recipe for whatever is recorded. CLOUDBOX_IGNORE_TBX does NOT
# relax it: that flag is about not being able to INSPECT tbx, and this is a fact
# this repo wrote down itself.
require_identity_match kind

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
    # Same caveat as substrate/docker.sh: this proves tbx has a RECORD of the
    # cluster, not that anything is running. An interrupted teardown leaves one.
    fail "tbx still has a '${CLUSTER_NAME}' cluster recorded (its VMs may or may not be running)."
    warn "Tear it down first:  CLOUDBOX_SUBSTRATE=tbx ./scripts/destroy-cluster.sh"
    warn "If that fails because tbx is half-installed or its helper is gone, the record is"
    warn "stale: remove it with 'tbx cluster destroy ${CLUSTER_NAME} --force', or skip tbx"
    die  "entirely with CLOUDBOX_IGNORE_TBX=1 (persist it in mise.local.toml)."
  elif [[ "${tbx_absent}" -eq 2 ]] && tbx_local_evidence "${CLUSTER_NAME}"; then
    fail "tbx is installed but cannot be inspected, so whether a '${CLUSTER_NAME}' cluster"
    fail "already exists on the tbx substrate is unknown:"
    printf '   %s\n' "${TBX_CLUSTER_ABSENT_REASON}"
    warn "This machine HAS created a tbx cluster before, and if its VMs are running the"
    warn "lifeboat would be a second cluster of the same name."
    die "Fix tbx ('tbx doctor'), or set CLOUDBOX_IGNORE_TBX=1 to proceed anyway."
  fi
fi
# The ports this script is about to publish. Same list, same probe and now the
# same helper as install.sh --check and the docker substrate's preflight
# (assert_host_ports_free / cloudbox_host_ports in lib.sh) — including port 80,
# the privileged one that makes the hostnames work without a port and the one
# whose holder is most often something else entirely. `kind create cluster`
# fails on a bound port AFTER creating containers, which is the wreck this
# refusal exists to avoid.
assert_host_ports_free \
  || die "Free them and re-run — kind would create the cluster and then fail to publish them."

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
