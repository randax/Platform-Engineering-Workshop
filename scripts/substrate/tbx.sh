#!/usr/bin/env bash
# =============================================================================
# substrate/tbx.sh — talos-box (`tbx`) backend: real Talos VMs.
#
# SUBSTRATE-ONLY path: talos-box guarantees VMs, networking, DNS and image
# delivery, and stops there (upstream docs/SPEC.md:19-21). We generate the
# machine config, apply it, bootstrap it, and let create-cluster.sh install OUR
# Cilium — the same sequence the docker backend runs, so one lab text covers
# both substrates.
#
# Source me from create-cluster.sh / destroy-cluster.sh; do not run me.
# Provides: substrate_preflight, substrate_create, substrate_destroy,
#           render_tbx_cluster_file, tbx_cluster_json, tbx_subnet_index,
#           tbx_node_ip.
# =============================================================================
set -euo pipefail

substrate_preflight() {
  need talosctl
  need kubectl
  need helm
  # Every introspection below reads `tbx status -o json`; jq is pinned in
  # mise.toml but nothing in create-cluster.sh required it until now.
  need jq
  need tbx "Install talos-box: 'brew install randax/tap/tbx && sudo tbx system install' (macOS) or the release tarball + systemd helper (Linux). Or run the docker substrate: CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh"
  # `tbx doctor` exits non-zero on any FAIL finding. It checks the helper, the
  # resolver, DNS wiring, forwarding, routes, host pressure, mirror health and
  # image access — all of which the workshop needs and none of which a bare
  # binary on PATH proves.
  # Deliberately run VISIBLY here even though substrate_resolve() has usually
  # already run it quietly during detection: detection only needs the exit code,
  # while an attendee who has been sent down this path needs to READ the FAIL
  # lines. The second run is the price of showing them, and doctor is read-only.
  if ! tbx doctor; then
    die "'tbx doctor' reports problems (above). Fix them, or run the fallback substrate: CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh"
  fi
  if tbx status "${CLUSTER_NAME}" >/dev/null 2>&1; then
    die "A '${CLUSTER_NAME}' tbx cluster already exists. Run ./scripts/destroy-cluster.sh first."
  fi
}

# render_tbx_cluster_file() — write ${TBX_CLUSTER_FILE} from
# scripts/substrate/cloudbox.tbx.yaml.tmpl, substituting the __TOKEN__
# placeholders with the TBX_* pins (and TALOS_VERSION / CLUSTER_NAME /
# CLOUDBOX_DOMAIN) from scripts/versions.env. The cluster yaml is a
# projection of those pins, never hand-edited and never checked in — see
# check 10 in scripts/check-consistency.sh.
render_tbx_cluster_file() {
  local tmpl="${SCRIPT_DIR}/substrate/cloudbox.tbx.yaml.tmpl"
  mkdir -p "$(dirname "${TBX_CLUSTER_FILE}")"
  # Worker vCPUs scale with the host, floored at the pin (versions.env:86):
  # max(TBX_WORKER_CPUS, NCPU-2), leaving 2 cores for the host and the
  # controlplane VM. Mirrors the same host-scaling idea as docker.sh's
  # NODE_CPUS, but floored instead of raised to the host count — the tbx
  # daemon (not the kernel) enforces the cap talos-box assigns the VM.
  local ncpu workers_cpus
  ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
  workers_cpus="$(awk -v n="${ncpu}" -v floor="${TBX_WORKER_CPUS}" \
    'BEGIN { c = int(n) - 2; if (c < floor) c = floor; printf "%d", c }')"
  sed \
    -e "s|__TALOS_VERSION__|${TALOS_VERSION}|g" \
    -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
    -e "s|__CLOUDBOX_DOMAIN__|${CLOUDBOX_DOMAIN}|g" \
    -e "s|__TBX_CP_MEMORY__|${TBX_CP_MEMORY}|g" \
    -e "s|__TBX_CP_CPUS__|${TBX_CP_CPUS}|g" \
    -e "s|__TBX_WORKER_MEMORY__|${TBX_WORKER_MEMORY}|g" \
    -e "s|__TBX_WORKER_CPUS__|${workers_cpus}|g" \
    -e "s|__TBX_DISK_SIZE__|${TBX_DISK_SIZE}|g" \
    "${tmpl}" > "${TBX_CLUSTER_FILE}"
}

# tbx_subnet_index / tbx_node_ip — read the cluster's facts from `tbx status
# -o json` rather than assuming them. Node addresses are NOT tied to creation
# order (on macOS the address is a vmnet DHCP lease keyed by the node's MAC, so
# a node can come up anywhere in the pool), so the control plane's address must
# be READ, never computed. The subnet index IS stable, and is what the .1
# gateway and the LoadBalancer pool are derived from (docs/SPEC.md:186-192).
# All three print the empty string when the answer cannot be read, and every
# caller checks for it. None of them may call die(): they run inside $( ),
# where a die would only kill the subshell and hand the caller an empty string
# anyway.
#
# `tbx status <cluster> -o json` prints a JSON ARRAY of ClusterStatus even for
# one named cluster (cmd/tbx/main.go:661-670 unmarshals into []ClusterStatus
# and encodes that) — hence the normaliser below, which also tolerates a bare
# object in case a later tbx unwraps it. A missing cluster is an error from
# `cluster.Load` (internal/daemon/operations.go:1446-1449), so a non-zero exit
# is what "no such cluster" looks like — which is what preflight and destroy
# key on.
tbx_cluster_json() {
  tbx status "${CLUSTER_NAME}" -o json 2>/dev/null \
    | jq --arg c "${CLUSTER_NAME}" \
        'if type == "array" then ((map(select(.name == $c)) | first) // {}) else . end' \
        2>/dev/null || true
}
tbx_subnet_index() {
  # .subnet is "172.30.<n>.0/24" (internal/cluster/cluster.go:193-195).
  tbx_cluster_json | jq -r '((.subnet // "") | split(".")[2]) // ""' 2>/dev/null || true
}
tbx_node_ip() { # <control-plane|worker>
  tbx_cluster_json \
    | jq -r --arg role "$1" '[.nodes[]? | select(.role == $role) | .ip] | first // ""' 2>/dev/null || true
}

# tbx_etcd_live <node-ip> — true when etcd is actually running on that node.
# Used to decide the bootstrap loop below on FACT rather than on the wording of
# a gRPC error: a bootstrap whose reply was lost to a client-side timeout still
# bootstrapped etcd, and asking the node is the only way to know that. Needs a
# TALOSCONFIG with credentials, so it is only meaningful after apply-config.
# `etcd status` is the direct question; `service etcd` is the fallback for a
# talosctl whose etcd subcommand set differs.
tbx_etcd_live() {
  talosctl --nodes "$1" etcd status >/dev/null 2>&1 && return 0
  talosctl --nodes "$1" service etcd 2>/dev/null | grep -qE '^STATE[[:space:]]+Running'
}

substrate_create() {
  step "Creating Talos VMs for '${CLUSTER_NAME}' (Talos ${TALOS_VERSION}, via tbx ${TBX_VERSION})"
  render_tbx_cluster_file
  info "Rendered ${TBX_CLUSTER_FILE}"
  # `tbx up` is file-driven and idempotent — it reconciles reality to the file.
  # Its only flags are -f / -force / -quiet, and it takes no cluster positional.
  # It holds its answer until the nodes it started answer on apid, up to a
  # bounded boot budget, and narrates its stages to stderr.
  tbx up -f "${TBX_CLUSTER_FILE}"

  step "Waiting for both nodes to reach Talos maintenance mode"
  # Capture with `|| unconfigured=0`: `set -o pipefail` would otherwise let a
  # single transient `tbx status` failure abort the whole script mid-wait.
  local waited=0 unconfigured=0
  while [[ "${waited}" -lt 300 ]]; do
    unconfigured="$(tbx_cluster_json \
      | jq -r '[.nodes[]? | select(.phase == "maintenance")] | length' 2>/dev/null)" \
      || unconfigured=""
    # An unreadable status is "0 nodes so far", not an empty count in the
    # timeout message below.
    [[ "${unconfigured}" =~ ^[0-9]+$ ]] || unconfigured=0
    [[ "${unconfigured}" == "2" ]] && break
    sleep 5
    waited=$((waited + 5))
  done
  [[ "${unconfigured}" == "2" ]] \
    || die "Only ${unconfigured}/2 nodes reached maintenance mode after ${waited}s — 'tbx status ${CLUSTER_NAME}' and 'tbx console ${CLUSTER_NAME} ${CLUSTER_NAME}-cp-1' show why"

  local idx cp_ip worker_ip
  idx="$(tbx_subnet_index)"
  cp_ip="$(tbx_node_ip control-plane)"
  worker_ip="$(tbx_node_ip worker)"
  [[ -n "${idx}" && -n "${cp_ip}" && -n "${worker_ip}" ]] \
    || die "Could not read the subnet and node addresses from 'tbx status ${CLUSTER_NAME} -o json'"
  export CLOUDBOX_HOST_GATEWAY="172.30.${idx}.1"
  # Always a COMPLETE URL — scheme and port included. Everything downstream
  # (the workshop context guard, the labs) treats this as something it can hand
  # straight to curl or to `talosctl gen config`.
  export CLOUDBOX_API_ENDPOINT="https://${cp_ip}:6443"
  info "Subnet 172.30.${idx}.0/24 — gateway ${CLOUDBOX_HOST_GATEWAY}, CP ${cp_ip}, worker ${worker_ip}"

  step "Generating the machine config (our patches, our sequence)"
  local workdir
  workdir="$(mktemp -d)"
  # SAME cni:none / proxy:disabled / node-label / local-path-mount patch as the
  # docker backend. One copy would be nicer; two identical heredocs is what
  # keeps each backend readable in isolation, and check-consistency.sh asserts
  # they stay byte-identical.
  local cni_patch balloon_patch mirror_patch tbx_mirror_patch endpoint reg
  cni_patch="$(cat <<'EOF'
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
  # virtio_balloon: tbxd's balloon manager needs the module loaded in the guest
  # (upstream internal/manifests/manifests.go:271-278). `tbx manifests <c>
  # balloon` is DEPRECATED and errors, and `tbx manifests <c> machine` would
  # also drag in a kubelet mount we do not use — so the two lines live here.
  balloon_patch="$(cat <<'EOF'
machine:
  kernel:
    modules:
      - name: virtio_balloon
EOF
  )"
  local patches=(--config-patch "${cni_patch}" --config-patch "${balloon_patch}")

  # Two mirror layers, and they do not conflict:
  #   * OUR eight explicit registries -> the crane mirror on the host, reached
  #     at the cluster gateway (host.docker.internal does not resolve inside a
  #     VM, which is why this is not mirror_host_endpoint()). skipFallback:false,
  #     exactly as on docker: a miss falls through to the real registry.
  #   * tbx's own catch-all "*" -> its pull-through mirror, which
  #     `tbx manifests <cluster> mirrors` renders. Explicit entries win over "*"
  #     in containerd, so this only covers registries our list does not name.
  #     Adopting tbx's mirror as the STORE is a non-goal; taking its catch-all
  #     costs nothing.
  if mirror_running; then
    endpoint="http://${CLOUDBOX_HOST_GATEWAY}:${MIRROR_PORT}"
    info "Image mirror detected — nodes will pull via ${endpoint}"
    # Built in ONE command substitution: appending several $( ) pieces would
    # silently join the lines, since command substitution eats trailing
    # newlines. The result is byte-identical to docker.sh's MIRROR_PATCH.
    mirror_patch="$(
      printf 'machine:\n  registries:\n    mirrors:\n'
      for reg in docker.io ghcr.io registry.k8s.io quay.io gcr.io public.ecr.aws \
                 xpkg.crossplane.io docker.gitea.com; do
        printf '      %s:\n        endpoints:\n          - %s\n        skipFallback: false\n' \
          "${reg}" "${endpoint}"
      done
    )"
    patches+=(--config-patch "${mirror_patch}")
  else
    warn "cloudbox-mirror registry is not running — nodes will pull from the internet."
    warn "Fine at home; at the venue run ./scripts/cloudbox-init.sh first."
  fi
  # Best-effort: a tbx with no mirror listener for this cluster renders nothing,
  # and that is not a reason to fail the create.
  tbx_mirror_patch="$(tbx manifests "${CLUSTER_NAME}" mirrors 2>/dev/null || true)"
  if [[ -n "${tbx_mirror_patch}" ]]; then
    patches+=(--config-patch "${tbx_mirror_patch}")
  else
    warn "'tbx manifests ${CLUSTER_NAME} mirrors' rendered nothing — skipping tbx's catch-all mirror"
  fi

  talosctl gen config "${CLUSTER_NAME}" "${CLOUDBOX_API_ENDPOINT}" \
    --kubernetes-version "${KUBERNETES_VERSION}" \
    --output-dir "${workdir}" \
    "${patches[@]}"

  step "Applying the machine config"
  # Node hostnames stay Talos' random talos-* on the substrate-only path. Do NOT
  # add machine.network.hostname to fix that: on Talos 1.13 every apply-config
  # then fails with "static hostname is already set in v1alpha1 config".
  talosctl apply-config --insecure --nodes "${cp_ip}"     --file "${workdir}/controlplane.yaml"
  talosctl apply-config --insecure --nodes "${worker_ip}" --file "${workdir}/worker.yaml"

  step "Bootstrapping etcd"
  # Remember what the caller had, exactly: "" and "unset" are different states,
  # and ${VAR+1} is the only way to tell them apart. Restored after the merge
  # below — create-cluster.sh's later steps, and anything that sources this,
  # must not inherit our temporary TALOSCONFIG or our unset of theirs.
  local orig_talosconfig="${TALOSCONFIG-}" orig_talosconfig_set="${TALOSCONFIG+1}"
  export TALOSCONFIG="${workdir}/talosconfig"
  talosctl config endpoint "${cp_ip}"
  talosctl config node "${cp_ip}"
  # The node reboots into the applied config first, so bootstrap is retried
  # until apid answers. A client-side timeout on a call the server DID run
  # leaves etcd bootstrapped and the next retry complaining about exactly that
  # — which is success, not failure. Talos words that complaint as
  #   rpc error: code = AlreadyExists desc = etcd data directory is not empty
  # so the glob has to be case-insensitive AND accept the "not empty" phrasing;
  # `*already*` alone silently misses the real reply and this loop would run its
  # full five minutes before failing a cluster that is already up.
  #
  # The string match is the fallback, not the test. tbx_etcd_live() asks the
  # node whether etcd is actually running: liveness beats parsing an error
  # message, and it is the one check that stays right when Talos rewords itself.
  local out bootstrapped=0
  for _ in $(seq 1 60); do
    if out="$(talosctl bootstrap 2>&1)"; then bootstrapped=1; break; fi
    if tbx_etcd_live "${cp_ip}"; then bootstrapped=1; break; fi
    case "${out}" in *[Aa]lready*|*"not empty"*) bootstrapped=1; break ;; esac
    sleep 5
  done
  [[ "${bootstrapped}" == "1" ]] \
    || die "etcd never bootstrapped after 5 minutes — 'talosctl --talosconfig ${workdir}/talosconfig dmesg' and 'tbx console ${CLUSTER_NAME} ${CLUSTER_NAME}-cp-1' show why"

  step "Merging kubeconfig"
  # No `docker port` rewrite here: the control plane's own address is routable
  # from the host (upstream docs/SPEC.md, "Reachability contract": host <-> node
  # IPs), so what talosctl writes is already correct on every platform.
  talosctl kubeconfig --force
  kubectl config use-context "admin@${CLUSTER_NAME}" >/dev/null
  ok "kubectl context: admin@${CLUSTER_NAME}"
  info "Kubernetes API: ${CLOUDBOX_API_ENDPOINT}"
  # Which FILE that landed in is decided by KUBECONFIG, which mise.toml pins to
  # ~/.kube/cloudbox.conf for this repo. Printed because it is the first thing
  # to check when kubectl later disagrees with you.
  info "kubeconfig: $(kubeconfig_in_use)"
  # Keep the talosconfig where `talosctl --context cloudbox dashboard` finds it:
  # unset TALOSCONFIG first, or the merge target is the file being merged.
  unset TALOSCONFIG
  talosctl config merge "${workdir}/talosconfig"
  # ...and put the caller's environment back the way we found it.
  if [[ -n "${orig_talosconfig_set}" ]]; then
    export TALOSCONFIG="${orig_talosconfig}"
  fi
  rm -rf "${workdir}"
}

substrate_destroy() {
  step "Destroying Talos VMs for '${CLUSTER_NAME}'"
  if tbx status "${CLUSTER_NAME}" >/dev/null 2>&1; then
    # `tbx down` only STOPS a cluster and has no --delete flag. Destroy is its
    # own verb, and --force is its confirmation.
    tbx cluster destroy "${CLUSTER_NAME}" --force
    ok "Cluster destroyed"
  else
    warn "No '${CLUSTER_NAME}' tbx cluster found — nothing to destroy"
  fi
  rm -f "${TBX_CLUSTER_FILE}"
}
