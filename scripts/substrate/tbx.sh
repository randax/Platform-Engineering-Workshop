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
# Provides: substrate_preflight, substrate_create, substrate_post_cni,
#           substrate_post_ready, substrate_destroy, render_tbx_cluster_file,
#           tbx_cluster_json, tbx_subnet_index, tbx_node_ip.
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
  # Shown here, whatever detection did with it: detection only needs the exit
  # code, and an attendee sent down this path needs to READ the FAIL lines.
  # tbx_doctor_run (lib.sh) memoises the run for the process, so showing them
  # costs a printf rather than a second full probe of the helper, DNS and routes.
  if ! tbx_doctor_run; then
    printf '%s\n' "${TBX_DOCTOR_OUT}"
    die "'tbx doctor' reports problems (above). Fix them, or run the fallback substrate: CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh"
  fi
  tbx_version_check die
  # Three-way, not two: "tbx cannot be inspected" is not "no cluster exists".
  # See tbx_cluster_absent() in lib.sh for the two error shapes and why the
  # narrow one is the only proof of absence.
  local absent=0
  tbx_cluster_absent "${CLUSTER_NAME}" || absent=$?
  case "${absent}" in
    1) # It exists — but "exists" covers two very different mornings. A cluster
       # whose every node is stopped or suspended is what a laptop looks like
       # after a reboot or a `tbx down`, and the answer there is to START it,
       # not to throw it away. Telling that attendee to destroy first costs them
       # the whole cluster and 20 minutes of re-create; `tbx cluster start|resume
       # <name>` (cmd/tbx/main.go) brings the same one back. Phases come from
       # `tbx status -o json`: stopped | suspended | unreachable | maintenance |
       # configured (internal/daemon/phase.go). WHICH verb matters:
       # tbx_restart_verb picks `resume` for a suspended cluster, because
       # `start` cold-boots it and discards the saved memory.
       if tbx_cluster_all_stopped; then
         local verb; verb="$(tbx_restart_verb)"
         fail "The '${CLUSTER_NAME}' tbx cluster exists, and every node is stopped or suspended."
         warn "That is a cluster waiting to be brought back, not one to throw away:"
         warn "  tbx cluster ${verb} ${CLUSTER_NAME}"
         warn "  ./scripts/create-cluster.sh --refresh-endpoint   # the VM addresses are DHCP leases and may have moved"
         die "Start it (or ./scripts/destroy-cluster.sh if you really want a new one), then re-run."
       fi
       die "A '${CLUSTER_NAME}' tbx cluster already exists. Run ./scripts/destroy-cluster.sh first." ;;
    2) fail "Could not ask tbx whether a '${CLUSTER_NAME}' cluster already exists:"
       printf '   %s\n' "${TBX_CLUSTER_ABSENT_REASON}"
       die "Creating over an existing cluster is worse than not creating. Fix the above (is tbxd running? 'tbx doctor'), then re-run." ;;
  esac
  # Leftover docker-substrate /etc/hosts entries are fatal HERE, before any VM
  # exists. They map *.${CLOUDBOX_DOMAIN} names to 127.0.0.1, and /etc/hosts is
  # consulted before talos-box's resolver — so the cluster would come up
  # perfectly and every single workshop URL would still hit the attendee's own
  # loopback. destroy-cluster.sh removes the block on the docker path now; this
  # catches the machine whose docker cluster was destroyed by hand, or before
  # that change existed — and, since the predicate is entries-or-markers rather
  # than the begin marker alone, also the file whose markers were deleted by
  # hand and whose 127.0.0.1 lines were left behind.
  # What is on the DOCKER daemon, before any VM is asked for. Two kinds of
  # cluster live there and `tbx status` is blind to both:
  #
  #   * a Talos-in-Docker cluster (label talos.cluster.name=<name>) — the
  #     migration case, and the one this preflight never looked for at all: a
  #     machine created on the docker substrate before the identity record
  #     existed (or one whose record was deleted) has a running cluster, an
  #     /etc/hosts block and a kubeconfig context, and `create-cluster.sh` on
  #     tbx built a SECOND cloudbox next to it;
  #   * the kind lifeboat (label io.x-k8s.kind.cluster=<name>).
  #
  # Both hold the ${CLOUDBOX_DOMAIN} names in /etc/hosts (consulted BEFORE
  # talos-box's resolver), host port 80, and the same workshop kubectl context.
  # The hosts-file guard below catches them only while their block is still
  # there — a cluster whose write_hosts_block was declined is invisible to it.
  # Asked of docker directly rather than of `talosctl`/`kind`: those binaries
  # may be gone; the containers are the fact.
  if have docker; then
    if docker_running; then
      local docker_talos docker_kind
      docker_talos="$(docker ps -aq --filter "label=talos.cluster.name=${CLUSTER_NAME}" 2>/dev/null || true)"
      docker_kind="$(kind_container_ids)"
      if [[ -n "${docker_talos}" ]]; then
        fail "A Talos-in-Docker cluster '${CLUSTER_NAME}' exists on this machine's Docker daemon (running or stopped)."
        warn "It holds the ${CLOUDBOX_DOMAIN} names in ${CLOUDBOX_HOSTS_FILE}, which override talos-box's"
        warn "resolver, and it answers on the same kubectl context this create is about to write."
        die "Tear it down first: CLOUDBOX_SUBSTRATE=docker ./scripts/destroy-cluster.sh"
      fi
      if [[ -n "${docker_kind}" ]]; then
        fail "A kind lifeboat cluster '${CLUSTER_NAME}' exists on this machine's Docker daemon (running or stopped)."
        warn "It holds the ${CLOUDBOX_DOMAIN} names in ${CLOUDBOX_HOSTS_FILE}, which override talos-box's"
        warn "resolver, and it answers on the same kubectl context this create is about to write."
        die "Tear it down first: ./scripts/kind-fallback.sh --delete"
      fi
    elif cloudbox_local_evidence; then
      # Docker is installed and cannot be inspected, and this machine carries a
      # trace of a CloudBox cluster having been built here. Whether that cluster
      # is a set of stopped containers waiting on that daemon is exactly the
      # question that cannot be answered — and creating VMs of the same name
      # over it is the collision above. tbx needs a running Docker daemon
      # anyway: the image mirror the VMs pull from is a Docker container.
      fail "The Docker daemon is not reachable, so whether a '${CLUSTER_NAME}' cluster already exists on it cannot be checked."
      warn "This machine carries traces of a CloudBox cluster (${CLOUDBOX_SUBSTRATE_FILE},"
      warn "${CLOUDBOX_API_ENDPOINT_FILE} or $(talos_cluster_state_dir)), so those containers"
      warn "may be sitting there stopped, holding this name, host port 80 and the ${CLOUDBOX_HOSTS_FILE} block."
      die "Start Docker and re-run — the tbx substrate needs it for the image mirror in any case."
    else
      warn "The Docker daemon is not reachable, so this preflight cannot check it for a"
      warn "'${CLUSTER_NAME}' cluster. Nothing on this machine says one was ever created here"
      warn "(no ${CLOUDBOX_SUBSTRATE_FILE}, no ${CLOUDBOX_API_ENDPOINT_FILE}, no"
      warn "$(talos_cluster_state_dir)), so there is nothing of ours to collide with. Continuing."
      warn "Note the cluster still needs the image mirror, which is a Docker container:"
      warn "  start Docker and run ./scripts/cloudbox-init.sh before the venue."
    fi
  fi
  if hosts_block_stale_for_tbx; then
    fail "${CLOUDBOX_HOSTS_FILE} still points CloudBox names at 127.0.0.1."
    warn "On tbx those lines OVERRIDE talos-box's resolver, so every"
    warn "*.${CLOUDBOX_DOMAIN} URL would reach your laptop instead of the cluster."
    local stray; stray="$(hosts_loopback_lines)"
    if [[ -n "${stray}" ]]; then
      warn "Delete these lines (line: text):"
      printf '   %s\n' "${stray}"
    else
      warn "A CloudBox marker is present with no entries under it — delete the marker."
    fi
    warn "Remove them: sudo \$EDITOR ${CLOUDBOX_HOSTS_FILE}  # markers ${CLOUDBOX_HOSTS_BEGIN} … ${CLOUDBOX_HOSTS_END} included"
    warn "  (or, if the docker cluster is still around: ./scripts/destroy-cluster.sh)"
    die "Remove them and re-run."
  fi
}


# tbx_worker_memory — the worker VM's memory as a GiB string for the cluster
# yaml. See the TBX_HOST_RESERVE_GIB block in versions.env for why this is
# derived and not simply the pin: `tbx up` ERRORS when planned VM memory
# exceeds host RAM minus its 6 GiB balloon reserve, which the flat 4+8 pair
# does on every 16 GB machine.
tbx_worker_memory() {
  local host_mib
  host_mib="$(tbx_host_memory_mib)"
  if [[ ! "${host_mib}" =~ ^[0-9]+$ ]]; then
    warn "Could not read this host's RAM — using the pinned ceiling ${TBX_WORKER_MEMORY} for the worker VM." >&2
    warn "If 'tbx up' then refuses on overcommit, lower TBX_WORKER_MEMORY in scripts/versions.env." >&2
    echo "${TBX_WORKER_MEMORY}"
    return 0
  fi
  # Clamped in awk, not with `(( … )) && …`: an arithmetic test that evaluates
  # to 0 exits non-zero, and the AND-list form of that is one `set -e` rewrite
  # away from being the last statement of a function.
  awk -v host="${host_mib}" -v cp="${TBX_CP_MEMORY%GiB}" \
      -v reserve="${TBX_HOST_RESERVE_GIB}" \
      -v floor="${TBX_WORKER_MEMORY_FLOOR%GiB}" -v cap="${TBX_WORKER_MEMORY%GiB}" \
    'BEGIN {
       g = int(host / 1024) - reserve - cp
       if (g > cap) g = cap
       if (g < floor) g = floor
       printf "%dGiB", g
     }'
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
  local ncpu workers_cpus workers_memory
  ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
  workers_cpus="$(awk -v n="${ncpu}" -v floor="${TBX_WORKER_CPUS}" \
    'BEGIN { c = int(n) - 2; if (c < floor) c = floor; printf "%d", c }')"
  # ...and worker MEMORY shrinks to the host in the same place, for the
  # opposite reason: too many vCPUs only oversubscribes, too much VM memory
  # makes `tbx up` refuse outright. See tbx_worker_memory() above.
  workers_memory="$(tbx_worker_memory)"
  info "Worker VM: ${workers_memory} / ${workers_cpus} vCPU · control plane: ${TBX_CP_MEMORY} / ${TBX_CP_CPUS} vCPU"
  sed \
    -e "s|__TALOS_VERSION__|${TALOS_VERSION}|g" \
    -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
    -e "s|__CLOUDBOX_DOMAIN__|${CLOUDBOX_DOMAIN}|g" \
    -e "s|__TBX_CP_MEMORY__|${TBX_CP_MEMORY}|g" \
    -e "s|__TBX_CP_CPUS__|${TBX_CP_CPUS}|g" \
    -e "s|__TBX_WORKER_MEMORY__|${workers_memory}|g" \
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

# tbx_cluster_all_stopped — 0 when the cluster has nodes and NONE of them is
# running. `stopped` and `suspended` are the two phases with no VM behind them
# (internal/daemon/phase.go: PhaseStopped, PhaseSuspended, and Phase.Stopped()
# treats them as one); `unreachable`, `maintenance` and `configured` all mean a
# VM is up. Empty or unreadable status is NOT "all stopped" — an absent answer
# must never turn into advice to start something.
tbx_cluster_all_stopped() {
  local verdict
  verdict="$(tbx_cluster_json | jq -r '
      if ((.nodes? // []) | length) == 0 then "unknown"
      elif [.nodes[] | select(.phase != "stopped" and .phase != "suspended")] | length == 0
        then "all-stopped" else "some-running" end' 2>/dev/null || true)"
  [[ "${verdict}" == "all-stopped" ]]
}

# tbx_restart_verb — "resume" or "start": which `tbx cluster <verb>` brings THIS
# cluster back. They are not interchangeable and only one of them is free.
#
# A SUSPENDED node has its RAM saved to disk; `tbx cluster resume` restores it
# and the cluster is back where it was. `tbx cluster start` on the same cluster
# is a COLD BOOT that deliberately discards those saves
# (internal/daemon/operations.go, the discardSavedState loop in the start op:
# "start is a cold boot: suspended memory left by an earlier suspend is
# superseded by these launches"). Both end with a running cluster, so the wrong
# verb never looks like an error — it just throws away the suspend and takes the
# slow path, which is the whole reason talos-box has two verbs.
#
# Says "start" when nothing is suspended, and when status cannot be read: start
# is the verb that works on a stopped cluster, and resume on one is an error.
tbx_restart_verb() {
  local any
  any="$(tbx_cluster_json | jq -r '[(.nodes? // [])[] | select(.phase == "suspended")] | length' 2>/dev/null || true)"
  if [[ "${any}" =~ ^[0-9]+$ ]] && [[ "${any}" -gt 0 ]]; then echo "resume"; else echo "start"; fi
}

# tbx_etcd_live <node-ip> — true when etcd is actually running on that node.
# Used to decide the bootstrap loop below on FACT rather than on the wording of
# a gRPC error: a bootstrap whose reply was lost to a client-side timeout still
# bootstrapped etcd, and asking the node is the only way to know that. Needs a
# TALOSCONFIG with credentials, so it is only meaningful after apply-config.
# `etcd status` is the direct question; `service etcd` is the fallback for a
# talosctl whose etcd subcommand set differs.
# Both probes are BOUNDED. talosctl has no client-side deadline of its own, and
# a node whose apid stops answering mid-create makes either call hang forever —
# which turned the bootstrap loop below into a silent, endless wait instead of
# the 10-minute failure with an actionable message it advertises. Ten seconds is
# far more than a healthy node needs to answer, and expiry is just "not live
# yet": the loop retries, and eventually gives up with the message.
tbx_etcd_live() {
  bounded 10 talosctl --nodes "$1" etcd status >/dev/null 2>&1 && return 0
  bounded 10 talosctl --nodes "$1" service etcd 2>/dev/null | grep -qE '^STATE[[:space:]]+Running'
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
  local cni_patch balloon_patch mirror_patch endpoint reg
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
  # user.max_user_namespaces: Talos ships it at 0 (no unprivileged user
  # namespaces). Module 07's rootless BuildKit (workflowtemplate-build-and-push)
  # needs to create one, and dies with "/proc/sys/user/max_user_namespaces needs
  # to be set to non-zero … fork/exec: no space left on device" otherwise. The
  # docker substrate never hit this: its node containers inherit the Docker/
  # Colima VM kernel, where the value is already non-zero (Colima: 15441).
  # Found by Rehearsal 5 step 7 on real tbx VMs; applies live, no reboot.
  local sysctl_patch
  sysctl_patch="$(cat <<'EOF'
machine:
  sysctls:
    user.max_user_namespaces: "10000"
EOF
  )"
  local patches=(--config-patch "${cni_patch}" --config-patch "${balloon_patch}" --config-patch "${sysctl_patch}")

  # ONE mirror layer: our eight explicit registries -> the crane mirror on the
  # host, reached at the cluster gateway (host.docker.internal does not resolve
  # inside a VM, which is why this is not mirror_host_endpoint()).
  # skipFallback:false, exactly as on docker: a miss falls through to the real
  # registry.
  #
  # DELIBERATELY NOT tbx's own catch-all. `tbx manifests <cluster> mirrors`
  # renders a RegistryMirrorConfig for `"*"` with `skipFallback: true`
  # (upstream internal/manifests/manifests.go:218-231), and containerd applies
  # `"*"` to every registry the config does not name EXPLICITLY — including
  # `localhost:30500`, which is how the kubelet pulls the images lab 07-09 and
  # the portal build into the in-cluster Zot. tbx's mirror refuses to proxy a
  # loopback or private authority (403 from validateResolvedAuthority /
  # namespaceIPBlocked, internal/mirror/manager.go:313-327 and 667-680), and
  # `skipFallback: true` forbids the direct pull that would otherwise rescue it
  # — so every first-party image would land in ImagePullBackOff. Our eight
  # explicit entries already cover everything in scripts/images.txt; the
  # catch-all bought nothing and cost module 07 onward.
  if mirror_running; then
    endpoint="http://${CLOUDBOX_HOST_GATEWAY}:${MIRROR_PORT}"
    info "Image mirror detected — nodes will pull via ${endpoint}"
    # ...and PROVE it, before that endpoint is baked into a machine config.
    # "the mirror container is running" and "the VMs can reach it" are different
    # claims, and only the second one matters here: the VMs reach the host at
    # its vmnet address 172.30.<n>.1, not at loopback, so a registry published
    # on 127.0.0.1 only (Colima and Lima default some port forwards that way,
    # and `docker run -p 127.0.0.1:5001:5000` does it explicitly) is up, healthy,
    # and completely unreachable from the nodes. Curling it from the HOST at the
    # gateway address is the same question the VM will ask: the gateway IS one
    # of this host's addresses, so a loopback-only bind fails here too.
    #
    # Fatal, not a warning: the whole point of the mirror is the venue, where
    # falling through to the real registries is exactly what does not work — and
    # the symptom lands 40 minutes later as ImagePullBackOff in module 02.
    # /v2/ is the registry API's cheapest liveness endpoint.
    if ! have curl; then
      warn "curl not found — cannot prove the mirror is reachable from ${CLOUDBOX_HOST_GATEWAY}."
      warn "If images fail to pull, check that it is bound to 0.0.0.0: docker port ${MIRROR_NAME}"
    elif ! curl -fsS --max-time 5 "${endpoint}/v2/" >/dev/null 2>&1; then
      fail "The image mirror is running but NOT reachable at ${endpoint}/v2/."
      warn "The Talos VMs reach this host at ${CLOUDBOX_HOST_GATEWAY} — a mirror bound to"
      warn "127.0.0.1 only is invisible to them, however healthy it looks locally."
      warn "  Colima/Lima: publish on 0.0.0.0 (colima start --network-address, and make sure"
      warn "  the container's port mapping is 0.0.0.0:${MIRROR_PORT}, not 127.0.0.1:${MIRROR_PORT})"
      warn "  Check what it is bound to: docker port ${MIRROR_NAME}"
      warn "  Then re-create the mirror: ./scripts/cloudbox-init.sh"
      warn "Or accept internet pulls for this run: docker rm -f ${MIRROR_NAME} (NOT at the venue)."
      die "Refusing to bake an unreachable mirror into the machine config."
    else
      ok "Mirror answers at ${endpoint}/v2/ from the cluster gateway address"
    fi
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
  #
  # And liveness is the ONLY success criterion, because a bootstrap that
  # returns 0 has not necessarily happened. On a first boot the node is still
  # pulling the control-plane images (etcd sits in "Preparing", waiting on
  # cri), apid answers long before that finishes, and the accepted request
  # lives only in memory: anything that restarts machined — a reboot, a
  # crashed pull being retried — drops it, etcd waits forever, and the API
  # wait downstream then fails on a cluster that is one `talosctl bootstrap`
  # away from healthy. Re-issuing is free (Talos answers "already exists"),
  # so issue it every round until the node says etcd is actually running.
  local bootstrapped=0
  for _ in $(seq 1 120); do
    bounded 30 talosctl bootstrap >/dev/null 2>&1 || true
    if tbx_etcd_live "${cp_ip}"; then bootstrapped=1; break; fi
    sleep 5
  done
  [[ "${bootstrapped}" == "1" ]] \
    || die "etcd never bootstrapped after 10 minutes — 'talosctl --talosconfig ${workdir}/talosconfig dmesg' and 'tbx console ${CLUSTER_NAME} ${CLUSTER_NAME}-cp-1' show why"

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
  # point TALOSCONFIG back at the CALLER's file first, or the merge target is
  # the throwaway workdir copy being merged.
  #
  # The caller's file — not `unset`. Unsetting sends the merge, the stale-context
  # reap and the select to ${HOME}/.talos/config, and then the caller's own
  # TALOSCONFIG is restored below: on a laptop where TALOSCONFIG points anywhere
  # else, the workshop's context lands in a file that attendee's talosctl never
  # reads. `talosctl --context cloudbox dashboard` says the context does not
  # exist, on a cluster this script has just declared healthy. This one
  # expression is the target for everything below, and it is what
  # remove_talos_context/has_talos_context resolve to as well (talos_config_target
  # in lib.sh), so create and destroy cannot act on two different files.
  export TALOSCONFIG="${orig_talosconfig:-${HOME}/.talos/config}"
  # Same stale-context reaper the docker backend runs, for the same reason and
  # against the same file: `talosctl config merge` will not overwrite an
  # existing context, it RENAMES the incoming one to '${CLUSTER_NAME}-1'. Every
  # `talosctl --context ${CLUSTER_NAME} dashboard` the labs and lab/01's verify
  # print would then dial the dead cluster's endpoint — silently, because a
  # renamed context is not an error. tbx clusters make this MORE likely than
  # docker ones did: the VM addresses are vmnet DHCP leases, so the stale
  # context's endpoint is not merely dead, it can be a DIFFERENT live machine.
  # Placed after the `unset TALOSCONFIG` above on purpose — that is what makes
  # ${TALOSCONFIG:-${HOME}/.talos/config} inside the helper name the merge
  # target rather than our own throwaway workdir copy.
  if has_talos_context "${CLUSTER_NAME}"; then
    warn "Removing a stale talosconfig context '${CLUSTER_NAME}' (it describes a cluster that no longer exists)"
    remove_talos_context "${CLUSTER_NAME}"
    if has_talos_context "${CLUSTER_NAME}"; then
      die "Could not remove the stale talosconfig context '${CLUSTER_NAME}' — remove it by hand (talosctl config remove ${CLUSTER_NAME}) and re-run."
    fi
  fi
  talosctl config merge "${workdir}/talosconfig"
  # Merge does not SELECT what it merged. Without this, `talosctl --context` is
  # fine but a bare `talosctl dashboard` still talks to whatever was selected
  # before — which on a re-create is the context we just reaped's replacement.
  talosctl config context "${CLUSTER_NAME}" >/dev/null 2>&1 \
    || warn "Could not select the '${CLUSTER_NAME}' talosconfig context — pass --context ${CLUSTER_NAME} to talosctl"
  # ...and put the caller's environment back EXACTLY as we found it — including
  # the case where they had no TALOSCONFIG at all, which the line above left
  # exported to the default path.
  if [[ -n "${orig_talosconfig_set}" ]]; then
    export TALOSCONFIG="${orig_talosconfig}"
  else
    unset TALOSCONFIG
  fi
  rm -rf "${workdir}"
}

# wait_crd_established <crd-name>... — the Cilium operator CREATES these CRDs
# at runtime (the helm install above has no --wait), so `kubectl wait
# --for=condition=Established` run against one that does not exist yet fails
# IMMEDIATELY with "no matching resources found" — `wait` waits for a
# condition, never for the object's creation. Poll each CRD into existence
# first, then wait on the condition. Same two-phase pattern as
# lab/common.sh's wait_for_cr() and lab/04-self-service/solve.sh:32-37
# (recurring finding across modules 03/04/06 in rehearsal-in-CI); not reused
# directly because lab/common.sh is lab-side (POSIX `[ ]`, sourced relative to
# a lab dir) and this file is bash with `set -euo pipefail` under scripts/.
wait_crd_established() {
  local crd
  for crd in "$@"; do
    local waited=0 found=0
    while [[ "${waited}" -lt 300 ]]; do
      if kubectl get "crd/${crd}" >/dev/null 2>&1; then
        found=1
        break
      fi
      sleep 5; waited=$((waited + 5))
    done
    [[ "${found}" == "1" ]] \
      || die "CRD ${crd} never appeared after ${waited}s — is the Cilium operator running? 'kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-operator'"
    kubectl wait --for=condition=Established --timeout=120s "crd/${crd}"
  done
}

# substrate_post_cni — run after Cilium is installed. Applies the LB-IPAM pool
# and the L2 announcement policy once their CRDs exist and are Established.
# Does NOT wait for the VIP here: that wait belongs in substrate_post_ready(),
# called after the node-Ready wait in create-cluster.sh, so a slow node
# rollout is never misreported as an ingress problem.
substrate_post_cni() {
  step "Applying the LoadBalancer pool and L2 announcement policy"
  wait_crd_established \
    ciliumloadbalancerippools.cilium.io \
    ciliuml2announcementpolicies.cilium.io
  # tbx_subnet_index() reads the fact from `tbx status -o json` (the same
  # source substrate_create() used to derive CLOUDBOX_HOST_GATEWAY) instead of
  # re-deriving it by string surgery on the gateway — one source of truth, and
  # this call also works if CLOUDBOX_HOST_GATEWAY were ever unset when this
  # function runs standalone (e.g. re-run by hand after a partial create).
  local idx
  idx="$(tbx_subnet_index)"
  [[ "${idx}" =~ ^[0-9]+$ ]] \
    || die "Could not read the subnet index from 'tbx status ${CLUSTER_NAME} -o json' (got '${idx}')"
  sed -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
      -e "s|__SUBNET_INDEX__|${idx}|g" \
      "${SCRIPT_DIR}/substrate/lb-objects.tbx.yaml.tmpl" \
    | kubectl apply -f -
}

# substrate_post_ready — run after nodes are Ready (Cilium's DaemonSet rolled
# out, L2 announcer running). Waits for the shared ingress Service to actually
# get its VIP: an ingress Service stuck <pending> is the single failure that
# makes every hostname in the workshop dead, so it is worth failing loudly
# here rather than in module 02.
substrate_post_ready() {
  step "Waiting for the shared ingress VIP"
  local idx
  idx="$(tbx_subnet_index)"
  [[ "${idx}" =~ ^[0-9]+$ ]] \
    || die "Could not read the subnet index from 'tbx status ${CLUSTER_NAME} -o json' (got '${idx}')"
  local waited=0 vip=""
  while [[ "${waited}" -lt 180 ]]; do
    vip="$(kubectl -n kube-system get svc cilium-ingress \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "${vip}" ]] && break
    sleep 5; waited=$((waited + 5))
  done
  [[ -n "${vip}" ]] \
    || die "cilium-ingress never got a LoadBalancer address after ${waited}s — kubectl -n kube-system describe svc cilium-ingress; kubectl get ciliumloadbalancerippools"
  # Not a warning. talos-box's resolver answers 172.30.<n>.200 for every
  # *.${CLOUDBOX_DOMAIN} name UNCONDITIONALLY (docs/SPEC.md:213-216) — it does
  # not look up which Service holds the address. So a cilium-ingress that landed
  # anywhere else in the .200-.239 pool means every hostname in the workshop
  # resolves to an address nothing is listening on, and the cluster otherwise
  # looks perfect: nodes Ready, Cilium green, the Service has "a VIP".
  # Continuing here would hand the attendee a cluster whose every URL is dead
  # and no error anywhere to explain it, and the diagnosis costs a module.
  # The cause is always another LoadBalancer Service that took .200 first.
  if [[ "${vip}" != "172.30.${idx}.200" ]]; then
    fail "cilium-ingress got ${vip}, not 172.30.${idx}.200."
    warn "talos-box's resolver answers 172.30.${idx}.200 for EVERY *.${CLOUDBOX_DOMAIN} name"
    warn "regardless of which Service holds it — so no workshop hostname would reach the ingress."
    warn "Something else took .200 first. Find it:"
    warn "  kubectl get svc -A --field-selector spec.type=LoadBalancer"
    warn "Delete that Service, then: ./scripts/destroy-cluster.sh && ./scripts/create-cluster.sh"
    die "Refusing to hand you a cluster whose hostnames all point at nothing."
  fi
  ok "Ingress VIP: ${vip} — every *.${CLOUDBOX_DOMAIN} name resolves here"
}

substrate_destroy() {
  step "Destroying Talos VMs for '${CLUSTER_NAME}'"
  need tbx "The cluster was created on the tbx substrate, so only tbx can remove its VMs. Install talos-box again, or remove them by hand before deleting ${CLOUDBOX_SUBSTRATE_FILE}."
  # Three-way (tbx_cluster_absent in lib.sh), because "cannot look" is not
  # "nothing there": the caller deletes ~/.cloudbox/substrate right after this
  # returns, and a machine with live VMs and no persisted substrate destroys as
  # docker forever after. The classifier is shared with both preflights so the
  # gate and the teardown cannot disagree about what "no such cluster" means —
  # and, in particular, so that a DOWN tbxd (whose dial error also ends in "no
  # such file or directory") can never be read as an absent cluster again.
  local absent=0
  tbx_cluster_absent "${CLUSTER_NAME}" || absent=$?
  case "${absent}" in
    1)
      # `tbx down` only STOPS a cluster and has no --delete flag. Destroy is its
      # own verb, and --force is its confirmation.
      tbx cluster destroy "${CLUSTER_NAME}" --force
      ok "Cluster destroyed" ;;
    0)
      warn "No '${CLUSTER_NAME}' tbx cluster found — nothing to destroy" ;;
    *)
      fail "'tbx status ${CLUSTER_NAME}' failed for a reason that is NOT 'no such cluster':"
      printf '   %s\n' "${TBX_CLUSTER_ABSENT_REASON}"
      warn "Nothing has been removed, and ${CLOUDBOX_SUBSTRATE_FILE} is left in place —"
      warn "if the VMs are still running, this is the only record that they are tbx's."
      die "Fix the above (is tbxd running? 'tbx doctor'), then re-run ./scripts/destroy-cluster.sh" ;;
  esac
  # Only after a successful destroy or a PROVEN absence.
  rm -f "${TBX_CLUSTER_FILE}"
}
