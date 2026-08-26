#!/usr/bin/env bash
# =============================================================================
# substrate/docker.sh — Talos-in-Docker backend (talosctl cluster create docker)
#
# This is the CI-proven path and the only one Windows/WSL2 and Codespaces can
# take. The body below is create-cluster.sh's, moved verbatim in the substrate
# split — behaviour-identical by construction. Do not "improve" it here: the
# comments in it record bugs that cost whole rehearsals.
#
# Source me from create-cluster.sh / destroy-cluster.sh; do not run me.
# Provides: substrate_preflight, substrate_create, substrate_post_cni,
#           substrate_post_ready, substrate_destroy.
# =============================================================================

substrate_preflight() {
  need talosctl
  need kubectl
  need helm
  need docker
  docker_running || die "Docker daemon is not reachable. Start Docker and re-run."
  # Talos labels every node container with talos.cluster.name=<cluster>
  if [[ -n "$(docker ps -aq --filter "label=talos.cluster.name=${CLUSTER_NAME}")" ]]; then
    die "A '${CLUSTER_NAME}' cluster already exists. Run ./scripts/destroy-cluster.sh first."
  fi
  # …and the THIRD thing that can hold this name on this very daemon: the kind
  # lifeboat. Its containers carry kind's own label, not Talos's, so the filter
  # above steps straight over them — and kind-fallback.sh has refused over
  # Talos containers since round 8 while this direction stayed open. A machine
  # whose identity record was lost (or never written, pre-round-8) then created
  # a Talos cluster on top of a running lifeboat: same name, same host ports,
  # same /etc/hosts block, two clusters. `-aq` for the same reason as above —
  # stopped kind nodes still own the ports and the name.
  if [[ -n "$(kind_container_ids)" ]]; then
    fail "A kind lifeboat cluster '${CLUSTER_NAME}' exists on this Docker daemon (running or stopped)."
    warn "It holds the same name, the same host ports and the same ${CLOUDBOX_HOSTS_FILE} block."
    die "Tear it down first: ./scripts/kind-fallback.sh --delete"
  fi
  # The MIRROR image of the tbx preflight's /etc/hosts guard: a '${CLUSTER_NAME}'
  # that already exists on the OTHER substrate is just as fatal, and much
  # quieter. The tbx VMs are alive, they hold the cluster name, the talosconfig
  # context and (on the tbx side) the resolver entries — and none of that is
  # visible to `docker ps`. Creating over it produces two clusters called
  # cloudbox, a talosconfig renamed to `cloudbox-1`, and a destroy that removes
  # whichever one the persisted substrate now says.
  #
  # `have tbx` first: a machine without talos-box cannot be in this state, and
  # this must not become a reason to require the binary on the docker path.
  #
  # The question is asked three-way (tbx_cluster_absent in lib.sh), and only a
  # PROVEN absence lets the create continue. The boolean version failed OPEN:
  # `tbx status` also exits non-zero when tbxd is down, which is exactly the
  # state a laptop is in after a reboot with the VMs still registered — so the
  # check read "no tbx cluster" precisely when it could not tell, and the two
  # clusters this exists to prevent got created anyway. CLOUDBOX_IGNORE_TBX=1 is
  # the escape hatch for someone who knows their tbx install is broken and only
  # wants a docker cluster.
  if have tbx && [[ "${CLOUDBOX_IGNORE_TBX:-}" != "1" ]]; then
    local absent=0
    tbx_cluster_absent "${CLUSTER_NAME}" || absent=$?
    if [[ "${absent}" -eq 1 ]]; then
      fail "A '${CLUSTER_NAME}' cluster already exists on the tbx substrate — its VMs are running."
      warn "Creating a docker cluster of the same name would leave two, with one talosconfig"
      warn "context between them and a destroy that can only find one."
      die "Destroy it first: CLOUDBOX_SUBSTRATE=tbx ./scripts/destroy-cluster.sh"
    elif [[ "${absent}" -eq 2 ]]; then
      # "Cannot inspect" is the state of a HALF-INSTALLED tbx: the binary is on
      # PATH (brew put it there) and tbxd has never run. That is the single most
      # likely reason someone falls back to docker in the first place, and
      # dying here turned the fallback into a dead end — on a machine that has
      # never created a tbx cluster at all.
      #
      # So ask the question tbxd cannot answer, of the filesystem, which does
      # not need a daemon: if NONE of the three persisted traces of a tbx
      # cluster is here (tbx_local_evidence in lib.sh), nothing this machine
      # ever created with tbx can be running, and the collision this guard
      # exists to prevent is impossible. Warn and continue. With any trace
      # present the ambiguity is real and this still dies.
      if ! tbx_local_evidence "${CLUSTER_NAME}"; then
        warn "tbx is installed but cannot be inspected:"
        printf '   %s\n' "${TBX_CLUSTER_ABSENT_REASON}"
        warn "No tbx cluster was ever created from this machine (no ${CLOUDBOX_SUBSTRATE_FILE},"
        warn "no ${TBX_CLUSTER_FILE}, no ~/.talosbox/clusters/${CLUSTER_NAME}), so there is nothing"
        warn "of ours running there. Continuing on the docker substrate."
      else
        fail "tbx is installed but cannot be inspected, so whether a '${CLUSTER_NAME}' cluster"
        fail "already exists on the tbx substrate is unknown:"
        printf '   %s\n' "${TBX_CLUSTER_ABSENT_REASON}"
        warn "This machine HAS created a tbx cluster before (${CLOUDBOX_SUBSTRATE_FILE},"
        warn "${TBX_CLUSTER_FILE} or ~/.talosbox/clusters/${CLUSTER_NAME} is present)."
        warn "If its VMs are running, a docker cluster of the same name would leave two."
        die "Fix tbx ('tbx doctor'), or set CLOUDBOX_IGNORE_TBX=1 to proceed anyway."
      fi
    fi
  fi
  # The ten host ports this substrate publishes, before `talosctl cluster create`
  # binds a single one. It publishes them AFTER creating the containers, so a
  # port held by anything else — another project's compose stack, a local nginx
  # on 80, a leftover mirror — fails the create with "bind: address already in
  # use" and leaves node containers, a state directory and a talosconfig context
  # behind for the next run to trip over. kind-fallback.sh has refused here since
  # round 8; the substrate that binds the same ports did not.
  assert_host_ports_free \
    || die "Free them and re-run — 'talosctl cluster create' publishes these AFTER creating the node containers, so it would leave a half-made cluster behind."
}

substrate_create() {
  # No containers, but a leftover talosconfig context named ${CLUSTER_NAME} makes
  # `talosctl cluster create` rename the NEW context to '${CLUSTER_NAME}-1' —
  # after which every `talosctl --context ${CLUSTER_NAME}` below dials the
  # endpoint of a cluster that no longer exists and this script fails at
  # "Merging kubeconfig". destroy-cluster.sh now clears it; this catches a stale
  # context left by an older destroy, a hand-run `talosctl cluster destroy`, or a
  # create that died halfway.
  #
  # The matching and removal are lib.sh's pipe-free helpers, shared with
  # destroy-cluster.sh and the tbx backend. They were pipelines here until the
  # `grep -vx` in the middle of them aborted the whole create under pipefail on
  # the one-context machine this branch exists for — see the comment above
  # talos_contexts() in lib.sh.
  if has_talos_context "${CLUSTER_NAME}"; then
    warn "Removing a stale talosconfig context '${CLUSTER_NAME}' (no such cluster is running)"
    remove_talos_context "${CLUSTER_NAME}"
    if has_talos_context "${CLUSTER_NAME}"; then
      die "Could not remove the stale talosconfig context '${CLUSTER_NAME}' — remove it by hand (talosctl config remove ${CLUSTER_NAME}) and re-run."
    fi
  fi

  # Second half of the same problem: `talosctl cluster create` also keeps a
  # provisioner STATE DIRECTORY, and it survives everything Docker-side. We know
  # there are no node containers by here, so a state directory left over from a
  # deleted Docker VM or a half-finished create describes nothing that exists —
  # and talosctl refuses to create over it ("state directory ... already exists").
  # See talos_cluster_state_dir() in lib.sh.
  STALE_STATE_DIR="$(talos_cluster_state_dir)"
  if [[ -d "${STALE_STATE_DIR}" ]]; then
    warn "Removing a stale Talos state directory '${STALE_STATE_DIR}' (no such cluster is running)"
    rm -rf "${STALE_STATE_DIR}"
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

  # CPU caps: talosctl defaults both to 2.0, which caps the whole cluster at 4
  # cores regardless of the host — enough for modules 00-05, not for the module 10
  # end state (21 apps, ~125 containers). Scale with the daemon's CPU count and
  # floor at talosctl's own default, so the published MIN_CPUS=4 machine gets
  # exactly what it got before and a bigger laptop actually gets used.
  # See TALOS_CPU_FLOOR in versions.env and docs/HAZARDS.md.
  host_cpus="$(docker info -f '{{.NCPU}}' 2>/dev/null || echo 0)"
  # Give BOTH containers the whole host and let the kernel share it. Deliberately
  # oversubscribed: a --cpus value equal to the host count is not a meaningful
  # quota, which is the point — nothing throttles. See TALOS_CPU_FLOOR above.
  NODE_CPUS="$(awk -v n="${host_cpus}" -v floor="${TALOS_CPU_FLOOR}" \
    'BEGIN { c = int(n); if (c < floor) c = floor; printf "%d", c }')"
  CPUS_CONTROLPLANE="${NODE_CPUS}"
  CPUS_WORKER="${NODE_CPUS}"
  info "Node CPUs: ${NODE_CPUS} each, uncapped by design (host has ${host_cpus})"

  # NodePorts are published on the controlplane container; Cilium's kube-proxy
  # replacement makes every NodePort answer on every node, so publishing them
  # from the controlplane alone reaches pods on the worker too.
  #
  # The last entry is the odd one out: host port 80 -> NODEPORT_INGRESS, the
  # nodePort Cilium's shared ingress Service is pinned to. That is what makes
  # http://<anything>.${CLOUDBOX_DOMAIN}/ work port-free on docker, the way it
  # does on tbx via a LoadBalancer VIP. The nine NodePorts above stay published
  # on purpose: lab 07 and the portal pull images through localhost:${NODEPORT_ZOT}
  # from the NODE side, and keeping the rest means a broken /etc/hosts block
  # degrades to "use the port URL", not "nothing works".
  # Wrapped rather than left to `set -e`: the ONE thing in that flag soup that
  # can fail for a reason outside this workshop is the last --exposed-ports
  # entry, host port 80. It is the only privileged port the workshop binds, and
  # anything already listening on it — a local web server, another Talos or kind
  # cluster, Colima/Lima's own privileged-port forwarder — makes the create die
  # with a docker port-binding error that names no owner. `install.sh --check`
  # tests port 80 only BEFORE a cluster exists, so a listener started since then
  # is exactly the case this message exists for. See docs/HAZARDS.md.
  if ! talosctl cluster create docker \
    --name "${CLUSTER_NAME}" \
    --image "${TALOS_IMAGE}" \
    --kubernetes-version "${KUBERNETES_VERSION}" \
    --workers 1 \
    --memory-controlplanes "${TALOS_MEMORY_CONTROLPLANE}" \
    --memory-workers "${TALOS_MEMORY_WORKER}" \
    --cpus-controlplanes "${CPUS_CONTROLPLANE}" \
    --cpus-workers "${CPUS_WORKER}" \
    --subnet "${TALOS_SUBNET}" \
    --exposed-ports "${NODEPORT_GITEA}:${NODEPORT_GITEA}/tcp,${NODEPORT_ARGOCD}:${NODEPORT_ARGOCD}/tcp,${NODEPORT_ZOT}:${NODEPORT_ZOT}/tcp,${NODEPORT_PORTAL}:${NODEPORT_PORTAL}/tcp,${NODEPORT_BACKSTAGE}:${NODEPORT_BACKSTAGE}/tcp,${NODEPORT_RUSTFS_S3}:${NODEPORT_RUSTFS_S3}/tcp,${NODEPORT_GRAFANA}:${NODEPORT_GRAFANA}/tcp,${NODEPORT_KOURIER}:${NODEPORT_KOURIER}/tcp,${NODEPORT_NATS}:${NODEPORT_NATS}/tcp,80:${NODEPORT_INGRESS}/tcp" \
    "${patches[@]}"; then
    fail "talosctl cluster create failed."
    warn "This cluster publishes host port 80 (-> NodePort ${NODEPORT_INGRESS}), the only"
    warn "privileged port the workshop binds — it is what makes http://<name>.${CLOUDBOX_DOMAIN}"
    warn "work without a port. If the error above mentions a port binding, port 80 is the"
    warn "likely culprit; here is what holds it:"
    port80_listeners
    warn "Stop that listener and re-run, or use the tbx substrate, whose ingress VIP needs"
    warn "no host port at all: CLOUDBOX_SUBSTRATE=tbx ./scripts/create-cluster.sh"
    exit 1
  fi

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
  # Which FILE all of the above landed in is decided by KUBECONFIG, which
  # mise.toml pins to ~/.kube/cloudbox.conf for this repo — talosctl and kubectl
  # both honour it, so the cluster ends up somewhere that holds nothing else and
  # destroy-cluster.sh leaves nothing to fall through to. Without mise in the
  # picture this is your ordinary ~/.kube/config, which also works. Printed
  # because it is the first thing to check when kubectl later disagrees with you.
  info "kubeconfig: $(kubeconfig_in_use)"

  # unset first: cloudbox_host_gateway() short-circuits on an existing value, and
  # a stale export from a previous run would be handed back unchanged.
  unset CLOUDBOX_HOST_GATEWAY
  CLOUDBOX_HOST_GATEWAY="$(cloudbox_host_gateway)"; export CLOUDBOX_HOST_GATEWAY
  # Must match the server the kubeconfig above actually carries, in BOTH
  # branches: when `docker port` gave us nothing, API_PORT is empty and
  # "https://127.0.0.1:${API_PORT}" would export the scheme and host of a URL
  # with no port at all — a string that looks like an endpoint and connects to
  # nothing. That branch left the kubeconfig as talosctl wrote it, which is the
  # node's in-network address, so say so.
  if [[ -n "${API_PORT}" ]]; then
    export CLOUDBOX_API_ENDPOINT="https://127.0.0.1:${API_PORT}"
  else
    export CLOUDBOX_API_ENDPOINT="https://${TALOS_CP_IP}:6443"
  fi
}

# substrate_post_cni / substrate_post_ready — nothing to do on docker. There
# is no L2 segment to announce a VIP onto, so the shared ingress Service is a
# NodePort (see the Cilium values in create-cluster.sh) and the hostnames
# arrive via the marked /etc/hosts block install.sh maintains. Defined so the
# dispatcher can call both unconditionally.
substrate_post_cni() { :; }
substrate_post_ready() { :; }

substrate_destroy() {
  step "Destroying Talos cluster '${CLUSTER_NAME}'"
  # A stopped daemon makes `docker ps -aq --filter …` print NOTHING and exit 0 —
  # indistinguishable from "there is no such cluster". The destroy would then
  # report "nothing to destroy", and destroy-cluster.sh would go on to remove
  # ~/.cloudbox/substrate and the state directory — erasing the record of a
  # cluster whose containers are all still there, waiting for Docker to come
  # back. The next create then trips over containers nothing remembers.
  docker_running \
    || die "Docker daemon is not reachable, so this cannot tell 'no cluster' from 'cannot look'. Start Docker and re-run — nothing has been removed."
  if [[ -n "$(docker ps -aq --filter "label=talos.cluster.name=${CLUSTER_NAME}")" ]]; then
    talosctl cluster destroy --name "${CLUSTER_NAME}" --force
    ok "Cluster destroyed"
  else
    warn "No '${CLUSTER_NAME}' cluster found — nothing to destroy"
  fi
  # `talosctl cluster destroy` removes the provisioner state directory itself, so
  # this is a no-op on the happy path. It is NOT a no-op on the path that brings
  # people here: no node containers (deleted Docker VM, hand-pruned containers, a
  # create that died after PKI generation) means the branch above found nothing
  # to destroy, while the state directory still blocks the next
  # create-cluster.sh. Without this, the documented recovery command does not
  # recover. See talos_cluster_state_dir() in lib.sh.
  local state_dir
  state_dir="$(talos_cluster_state_dir)"
  if [[ -d "${state_dir}" ]]; then
    rm -rf "${state_dir}"
    ok "Talos cluster state directory removed (${state_dir})"
  fi
}
