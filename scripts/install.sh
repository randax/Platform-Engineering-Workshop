#!/usr/bin/env bash
# =============================================================================
# install.sh — CloudBox pre-flight check (step 3, the go/no-go gate)
#
# Checks that this machine can run the workshop. --check and --print-hosts only
# READ state — they install nothing, touch no cluster, pull no images. The two
# mutating modes are --write-hosts and --add-hosts; both are opt-in and run only
# on the docker and kind identities
# and say what they are doing.
#
# Usage:
#   ./scripts/install.sh --check    # run the pre-flight check
#   ./scripts/install.sh            # same check + usage text
#   ./scripts/install.sh --print-hosts   # the /etc/hosts lines the docker substrate needs
#   ./scripts/install.sh --write-hosts   # docker/kind only: (re)write that block —
#                                   the recovery path when create-cluster.sh's
#                                   sudo was declined, and the refresh path
#                                   after WSL2 regenerates /etc/hosts
#   ./scripts/install.sh --add-hosts <name>...   # docker/kind only: resolve extra
#                                   Knative names (e.g. my-app-demo) — WRITES
#                                   /etc/hosts, asks for sudo
#
# Checked:
#   * CPU architecture (amd64/arm64) and WSL2 hints
#   * Docker daemon reachable; CPUs/RAM allocatable to Docker; free disk
#   * Required CLI tools present at the pinned versions
#   * Pre-pulled images from scripts/images.txt (host cache + mirror registry)
#   * Which substrate will be used, and the workshop hostnames resolving
#
# Exit code: 0 = ready for the workshop, 1 = at least one check failed.
# If a check fails, fix it and re-run. Failing machines can still join via
# the devcontainer/Codespaces lifeboat — see the repo README.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

usage() {
  # print this script's header comment block as the usage text
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
  --check) ;;
  # Read-only, and the ONE thing a Windows attendee needs: these lines also have
  # to go into C:\Windows\System32\drivers\etc\hosts for the Windows browser to
  # reach a cluster running in WSL2 (lab/00-setup covers it). The block goes to
  # stdout and the note to stderr, so `--print-hosts | sudo tee -a /etc/hosts`
  # still writes exactly the block.
  --print-hosts)
    cloudbox_hosts_block
    {
      echo
      echo "# ^ paste into ${CLOUDBOX_HOSTS_FILE} (or let ./scripts/create-cluster.sh do it)."
      echo "# WSL2: these lines belong in BOTH the WSL2 /etc/hosts and the Windows"
      printf '%s\n' '#       C:\Windows\System32\drivers\etc\hosts (edit as Administrator) —'
      echo "#       the Windows browser resolves names itself, and only reads that file."
      echo "# tbx substrate: not needed — talos-box's resolver answers ${CLOUDBOX_DOMAIN}."
    } >&2
    exit 0 ;;
  # The re-entrant writer. Everything else that writes the block needs something
  # from the caller (a cluster to create, a name to add); this one takes nothing
  # and rewrites the block from the pins plus ${CLOUDBOX_EXTRA_HOSTS_FILE}, so
  # it is the answer to every "the names stopped resolving" state:
  #   * create-cluster.sh's sudo was declined — the cluster is up and healthy,
  #     and re-running the create is refused by preflight (its own containers);
  #   * WSL2 regenerated /etc/hosts from the Windows file at restart and threw
  #     the block away (see lab/00-setup: /etc/wsl.conf generateHosts = false);
  #   * a name was removed from the extras file and its 127.0.0.1 line is still
  #     in /etc/hosts.
  # Idempotent: with a correct block it writes nothing and asks for no password.
  --write-hosts)
    shift
    [[ $# -eq 0 ]] || { usage; die "--write-hosts takes no arguments (to add a name: --add-hosts <name>)"; }
    # A mutating mode, so the record has to be readable before the decision is
    # even made (lib.sh, assert_identity_readable) — a tbx machine whose record
    # cannot be read must not have the 127.0.0.1 block written over its
    # resolver because the file looked absent.
    assert_identity_readable
    # Assigned, never compared inline (lib.sh's substrate_resolve): an invalid
    # CLOUDBOX_SUBSTRATE makes it fail, and inside `[[ "$(…)" != docker ]]` that
    # failure is invisible — the empty string is simply "not docker", so the
    # attendee was told `--write-hosts` is tbx-only when the real problem was a
    # typo in their own override.
    write_substrate="$(substrate_resolve)"
    # docker OR kind: the lifeboat maps host port 80 to the ingress NodePort and
    # is written against the same block (kind-fallback.sh calls this same
    # writer). Refusing there would leave the one documented repair —
    # "the names stopped resolving" — with no command on the machine that needs
    # it most.
    if [[ "${write_substrate}" != "docker" && "${write_substrate}" != "kind" ]]; then
      die "--write-hosts works on the docker and kind identities only. On tbx, talos-box's resolver answers every *.${CLOUDBOX_DOMAIN} name — 127.0.0.1 lines would override it and send every URL to your own loopback."
    fi
    # …and only when that is also what this machine has RECORDED. This writes to
    # /etc/hosts with sudo, and `CLOUDBOX_SUBSTRATE=docker ./scripts/install.sh
    # --write-hosts` on a tbx machine wrote exactly the block substrate_preflight
    # dies on — the one that overrides talos-box's resolver and sends every
    # workshop URL to the attendee's own loopback, on a healthy cluster.
    require_identity_match "${write_substrate}"
    write_hosts_block
    exit 0 ;;
  # /etc/hosts has no wildcards, so on the docker substrate only the names
  # create-cluster.sh enumerated resolve. The three ksvcs the labs create are
  # knowable in advance; a Console-composed Application (module 08) or anything
  # an attendee names themselves is not. This persists the short name in
  # ${CLOUDBOX_EXTRA_HOSTS_FILE} — so the NEXT rewrite of the block keeps it —
  # and rewrites the block now.
  #
  # tbx needs none of this: talos-box's resolver answers the whole
  # *.${KNATIVE_DOMAIN} wildcard, so the command refuses there rather than
  # writing lines that would OVERRIDE that resolver with 127.0.0.1.
  --add-hosts)
    shift
    [[ $# -gt 0 ]] || { usage; die "--add-hosts needs at least one name, e.g. --add-hosts my-app-demo"; }
    # Same first question as --write-hosts, for the same reason: this ends in
    # the same privileged rewrite of the same block.
    assert_identity_readable
    add_substrate="$(substrate_resolve)"
    # docker OR kind, for the same reason --write-hosts accepts both: /etc/hosts
    # has no wildcards on either, and module 08's Knative names are exactly as
    # unresolvable on the lifeboat as they are on the docker substrate.
    if [[ "${add_substrate}" != "docker" && "${add_substrate}" != "kind" ]]; then
      die "--add-hosts works on the docker and kind identities only. On tbx, talos-box's resolver already answers every *.${KNATIVE_DOMAIN} name — adding 127.0.0.1 lines would override it and send every URL to your own loopback."
    fi
    # Same guard, same reason as --write-hosts: this ends in the same privileged
    # rewrite of the same block.
    require_identity_match "${add_substrate}"
    # ALL of them validated before ANY of them is persisted. Persisting as we go
    # made `--add-hosts good-name Bad_Name` write half the request and then die:
    # the extras file kept the first name, /etc/hosts was never rewritten, and
    # re-running the corrected command was the only way to find out which half
    # had landed. Validation is free; a partially applied mutation is not.
    for name in "$@"; do
      cloudbox_valid_label "${name}" \
        || die "'${name}' is not a DNS label — RFC 1123 allows lowercase letters, digits and '-', starting and ending alphanumeric, at most 63 characters (pass the FIRST label only, e.g. my-app-demo for my-app-demo.${KNATIVE_DOMAIN}). Nothing was changed."
    done
    # The persist has to come FIRST — cloudbox_hostnames() reads the extras file,
    # so it is what the block is rendered from — but it must not SURVIVE a failed
    # write. The privileged write is the step an attendee can decline, and a
    # declined password used to leave the name recorded as "resolvable" while
    # /etc/hosts had never heard of it: `--check` then reported a missing name
    # for a service the attendee never successfully added, and only a hand edit
    # of the extras file cleared it. So: snapshot, persist, write, and put the
    # snapshot back if the write did not happen.
    extras_backup="$(mktemp)"
    extras_existed="false"
    if [[ -f "${CLOUDBOX_EXTRA_HOSTS_FILE}" ]]; then
      extras_existed="true"
      cp "${CLOUDBOX_EXTRA_HOSTS_FILE}" "${extras_backup}"
    fi
    for name in "$@"; do
      cloudbox_add_extra_host "${name}"
      info "will resolve: ${name}.${KNATIVE_DOMAIN}"
    done
    if ! write_hosts_block; then
      if [[ "${extras_existed}" == "true" ]]; then
        cp "${extras_backup}" "${CLOUDBOX_EXTRA_HOSTS_FILE}"
      else
        rm -f "${CLOUDBOX_EXTRA_HOSTS_FILE}"
      fi
      rm -f "${extras_backup}"
      fail "Nothing was added: ${CLOUDBOX_EXTRA_HOSTS_FILE} is back as it was, so the names it lists and the ones ${CLOUDBOX_HOSTS_FILE} resolves still agree."
      warn "Fix what the write complained about (above), then re-run: ./scripts/install.sh --add-hosts $*"
      exit 1
    fi
    rm -f "${extras_backup}"
    info "Remove one again: \$EDITOR ${CLOUDBOX_EXTRA_HOSTS_FILE}   # then: ./scripts/install.sh --write-hosts"
    exit 0 ;;
  "") usage; echo ;;
  -h|--help) usage; exit 0 ;;
  *) usage; die "Unknown argument: $1 (this script only checks and prints; it installs nothing)" ;;
esac

failures=0
check_fail() { fail "$*"; failures=$((failures + 1)); }

step "CloudBox pre-flight check"

# --- Platform -------------------------------------------------------------------
if arch="$(detect_arch)"; then
  ok "CPU architecture: ${arch}"
else
  check_fail "Unsupported CPU architecture '$(uname -m)' (need x86_64 or arm64)"
fi

os="$(uname -s)"
if is_wsl2; then
  ok "Platform: WSL2 (best-effort support — pair up if things get weird)"
  info "WSL2 hints: give the WSL2 VM >= 12 GB memory via %UserProfile%\\.wslconfig"
  info "  [wsl2]"
  info "  memory=12GB"
  info "and use the Docker Desktop WSL2 backend (Settings -> Resources -> WSL integration)."
elif [[ "${os}" == "Darwin" || "${os}" == "Linux" ]]; then
  ok "Platform: ${os}"
else
  check_fail "Unsupported platform: ${os} (macOS, Linux or WSL2 required)"
fi

# Which substrate create-cluster.sh would pick, resolved ONCE and reused below.
# Read-only: substrate_resolve_into() only reads the override, the persisted file
# and `tbx doctor` — it never writes, so --check stays a check.
#
# The _into form, not `$(substrate_resolve)`: detection memoises `tbx doctor` in
# TBX_DOCTOR_RC, and a command substitution is a subshell that throws that memo
# away — so the visible `tbx doctor` run below, and substrate_doctor_reason,
# each re-probed the helper, DNS, routes and mirror from scratch.
SUBSTRATE=""
substrate_resolve_into SUBSTRATE
info "Substrate: ${SUBSTRATE}"
if [[ "${SUBSTRATE}" == "docker" && -z "${CLOUDBOX_SUBSTRATE:-}" && -z "$(substrate_current)" ]]; then
  info "  (tbx not used: $(substrate_doctor_reason))"
fi
# The lifeboat is graded with DOCKER semantics throughout this file — its nodes
# are containers on this host's Docker engine, it publishes the same host ports
# and it needs the same /etc/hosts block — and with none of the tbx ones. Said
# once, here, because every branch below reads as a docker branch after this.
if [[ "${SUBSTRATE}" == "kind" ]]; then
  info "  (the kind lifeboat: checked like the docker substrate — same host ports, same ${CLOUDBOX_HOSTS_FILE} block. Create and destroy it with ./scripts/kind-fallback.sh [--delete]; ./scripts/create-cluster.sh and ./scripts/destroy-cluster.sh refuse here.)"
fi
# Everything tbx-specific, in one place, and NONE of it silently skipped.
#
# The previous shape was `if [[ tbx ]] && have tbx` — which turned the one state
# that cannot work (tbx resolved, binary gone: an explicit CLOUDBOX_SUBSTRATE=tbx,
# or a persisted answer whose brew formula has since been uninstalled) into a
# preflight that passes. A machine that cannot create a cluster read as ready.
if [[ "${SUBSTRATE}" == "tbx" ]]; then
  if ! have tbx; then
    check_fail "substrate is tbx but the 'tbx' binary is not on PATH — install talos-box (brew install randax/tap/tbx && sudo tbx system install), or run the docker substrate: CLOUDBOX_SUBSTRATE=docker"
  else
    # The pin this laptop will actually run. check-consistency.sh check 10 only
    # proves versions.env and mise.toml agree with each other — mise has no tbx
    # backend to install from, so the binary on PATH is unasserted until here.
    tbx_version_check check_fail
    # `tbx doctor` is the tbx substrate's real preflight: helper, resolver, DNS
    # wiring, forwarding, routes, host pressure, mirror health, image access.
    # substrate_preflight runs it on the create path and dies; running it HERE
    # is the point of a go/no-go gate — an attendee finds out at home, not at
    # the venue. Read-only, so it belongs in --check. Output is shown: the FAIL
    # lines are the actionable part, and summarising them would lose them.
    # The memoised run (lib.sh): substrate_resolve above has usually already
    # asked, and doctor is the slowest read-only probe here. Printed in full —
    # an attendee sent down this path needs to READ the FAIL lines.
    if ! tbx_doctor_run; then
      printf '%s\n' "${TBX_DOCTOR_OUT}"
      check_fail "'tbx doctor' reports problems (above) — fix them, or run the docker substrate: CLOUDBOX_SUBSTRATE=docker"
    else
      ok "tbx doctor is clean"
    fi
  fi
  # The one pinned image with no arm64 build. tbx VMs are native — nothing
  # emulates amd64 inside them — so on an arm64 host the Backstage pod
  # crashloops with "exec format error" where the docker substrate (Docker
  # Desktop/OrbStack emulation) merely runs it slowly. A warning, not a
  # check_fail: Backstage is a stretch catalog item and a presenter demo, and no
  # core module touches it.
  # host_cpu_arch, not detect_arch: the VMs follow the hardware, and in a Rosetta
  # shell on Apple Silicon uname says x86_64 while the nodes are still arm64.
  if [[ "$(host_cpu_arch 2>/dev/null || true)" == "arm64" ]]; then
    warn "Backstage (${MIRROR_ARCH_EXEMPT}) is published for linux/amd64 only and your tbx nodes are arm64 VMs with no emulation — enabling gitops/catalog/backstage.yaml here ends in 'exec format error'. It is a stretch catalog item; to try it, run that cluster on the docker substrate (CLOUDBOX_SUBSTRATE=docker). Everything else in the workshop is multi-arch."
  fi
  # The memory budget that actually applies on this substrate. The VMs are sized
  # from the HOST's RAM (tbx_worker_memory()), and `tbx up` REFUSES to start a
  # cluster whose planned VM memory exceeds host RAM minus tbxd's 6 GiB balloon
  # reserve — so the number to publish and check here is the host's, not
  # Docker's slice. Same probe tbxd uses (lib.sh, tbx_host_memory_mib).
  host_mib="$(tbx_host_memory_mib)"
  if [[ "${host_mib}" =~ ^[0-9]+$ ]]; then
    host_gb=$(( host_mib / 1024 ))
    if [[ "${host_gb}" -ge "${MIN_HOST_MEMORY_GB}" ]]; then
      ok "Host memory: ${host_gb} GB (need >= ${MIN_HOST_MEMORY_GB} GB)"
    else
      check_fail "Host memory: ${host_gb} GB — the published minimum is ${MIN_HOST_MEMORY_GB} GB. On tbx the VMs are sized from host RAM, so this is the budget that matters; 'tbx up' refuses a plan that does not fit."
    fi
  else
    warn "Could not read this host's RAM — the tbx VM sizing falls back to the pinned ceiling"
  fi

  # The CPU half of the same budget. Docker's NCPU gate below is docker-only —
  # correctly, since on tbx the nodes are VMs — which left MIN_CPUS, a published
  # promise, unenforced on this substrate entirely. The worker VM is sized
  # max(TBX_WORKER_CPUS, NCPU-2) from exactly this number (substrate/tbx.sh),
  # so it is the budget that matters here.
  host_cpus="$(host_cpu_count)"
  if [[ "${host_cpus}" =~ ^[0-9]+$ ]]; then
    if [[ "${host_cpus}" -ge "${MIN_CPUS}" ]]; then
      ok "Host CPUs: ${host_cpus} (need >= ${MIN_CPUS})"
    else
      check_fail "Host CPUs: ${host_cpus} — the published minimum is ${MIN_CPUS}. On tbx the node VMs take their cores from the host, so there is no setting to raise; use a bigger machine, or the docker substrate with CLOUDBOX_SUBSTRATE=docker."
    fi
  else
    warn "Could not read this host's core count — MIN_CPUS=${MIN_CPUS} not verified"
  fi
fi

# --- Docker ---------------------------------------------------------------------
if ! have docker; then
  # A hard FAIL on BOTH substrates, on purpose. tbx replaces the NODES, not the
  # mirror: cloudbox-init.sh's crane mirror is itself a Docker container
  # (cloudbox-mirror on :${MIRROR_PORT}), and it is what every node pulls from
  # offline. A tbx laptop without Docker can start a cluster and then has
  # nothing to pull images from at the venue.
  check_fail "docker CLI not found — install Docker Desktop, OrbStack or docker-ce. Needed on the tbx substrate too: the offline image mirror the VMs pull from is a Docker container (./scripts/cloudbox-init.sh)"
elif ! docker_running; then
  check_fail "Docker daemon not reachable — is Docker started?"
else
  ok "Docker daemon reachable ($(docker info -f '{{.OperatingSystem}}' 2>/dev/null))"

  # The CPU/RAM budget below is the NODE budget, and on tbx the nodes are not
  # containers: they are VMs sized from the HOST's RAM (tbx_worker_memory() in
  # substrate/tbx.sh), and Docker's slice is irrelevant to them. Docker is still
  # required on tbx — the offline image mirror is a Docker container — but a
  # mirror is a registry serving blobs, which needs neither 4 CPUs nor 10 GB.
  # Failing a perfectly good tbx laptop over a small Docker VM would send an
  # attendee to raise a limit that changes nothing they will use.
  # kind counts as docker here: its nodes are containers on this daemon too, and
  # they run the same workshop.
  if [[ "${SUBSTRATE}" == "docker" || "${SUBSTRATE}" == "kind" ]]; then
    # CPUs available to Docker
    ncpu="$(docker info -f '{{.NCPU}}' 2>/dev/null || echo 0)"
    if [[ "${ncpu}" -ge "${MIN_CPUS}" ]]; then
      ok "Docker CPUs: ${ncpu} (need >= ${MIN_CPUS})"
    else
      check_fail "Docker CPUs: ${ncpu} — need >= ${MIN_CPUS}. Raise it in Docker settings."
    fi

    # Memory allocatable to Docker (on Linux this is host RAM; on macOS/WSL2 the VM)
    mem_bytes="$(docker info -f '{{.MemTotal}}' 2>/dev/null || echo 0)"
    mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
    if [[ "${mem_gb}" -ge "${MIN_DOCKER_MEMORY_GB}" ]]; then
      ok "Memory allocatable to Docker: ${mem_gb} GB (need >= ${MIN_DOCKER_MEMORY_GB} GB)"
    else
      check_fail "Memory allocatable to Docker: ${mem_gb} GB — need >= ${MIN_DOCKER_MEMORY_GB} GB"
      info "  Docker Desktop: Settings -> Resources -> Memory. OrbStack: orb config set memory_mib."
    fi
  else
    info "Docker's CPU/RAM budget not checked — on tbx it only has to run the image mirror."
  fi

  # Free disk where Docker stores images. On macOS/WSL2 the Docker root dir
  # lives inside the VM, so fall back to checking the home filesystem too.
  docker_root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"
  df_target="${HOME}"
  [[ -n "${docker_root}" && -d "${docker_root}" ]] && df_target="${docker_root}"
  free_kb="$(df -Pk "${df_target}" | awk 'NR==2 {print $4}')"
  free_gb=$(( free_kb / 1024 / 1024 ))
  if [[ "${free_gb}" -ge "${MIN_DISK_FREE_GB}" ]]; then
    ok "Free disk on ${df_target}: ${free_gb} GB (need >= ${MIN_DISK_FREE_GB} GB)"
  else
    check_fail "Free disk on ${df_target}: ${free_gb} GB — need >= ${MIN_DISK_FREE_GB} GB"
  fi
fi

# --- Host ports --------------------------------------------------------------------
# DOCKER ONLY. Every port in this list is a host port because the docker
# backend PUBLISHES it off the controlplane container. On tbx nothing is
# published: the NodePorts live inside the VMs, reached at the node addresses,
# and the ingress is a LoadBalancer VIP on the cluster's own L2 segment. So a
# busy 30300 on a tbx laptop is somebody else's business entirely — failing
# preflight on it would send an attendee hunting for a listener that cannot
# affect them, and (worse) a machine that is FINE reads as not ready.
step "Workshop host ports"
if [[ "${SUBSTRATE}" == "tbx" ]]; then
  ok "tbx substrate — the workshop publishes no host ports at all"
  info "  (NodePorts live inside the VMs; the ingress is a LoadBalancer VIP on the cluster's own segment)"
elif [[ "${SUBSTRATE}" == "kind" ]]; then
  # The lifeboat publishes exactly what the docker substrate does — the nine
  # NodePorts plus host 80 → the ingress NodePort — from the worker container.
  # So with its cluster up these ports are SUPPOSED to be bound, and scanning
  # them would report ten failures on a healthy machine.
  if ! have kind; then
    check_fail "${CLOUDBOX_SUBSTRATE_FILE} says 'kind' but the 'kind' binary is not on PATH — run ./scripts/dev-setup.sh (mise pins it), or remove that file if you are done with the lifeboat"
  elif kind_cluster_exists; then
    if kind_nodes_running; then
      ok "kind lifeboat '${CLUSTER_NAME}' is running (both nodes) — its ports are expected to be bound"
    else
      # BOTH nodes, named. Every host port the lifeboat publishes is mapped from
      # the WORKER container (kind-fallback.sh's extraPortMappings sit under
      # `role: worker`), so "the control plane is up" was the wrong question:
      # with the worker stopped this said "running — ports expected to be bound"
      # about a cluster that answers no workshop URL at all.
      check_fail "the kind lifeboat '${CLUSTER_NAME}' is not running both nodes — stopped: $(kind_nodes_missing)"
      echo "     (host port 80 and every NodePort are published from ${CLUSTER_NAME}-worker, so a"
      echo "      stopped worker means no *.${CLOUDBOX_DOMAIN} URL resolves to anything.)"
      echo "     Bring it back:  docker start ${CLUSTER_NAME}-control-plane ${CLUSTER_NAME}-worker"
      echo "     Or start over:  ./scripts/kind-fallback.sh --delete && ./scripts/kind-fallback.sh"
    fi
  else
    check_fail "${CLOUDBOX_SUBSTRATE_FILE} says 'kind' but no kind cluster '${CLUSTER_NAME}' exists — create it with ./scripts/kind-fallback.sh, or remove that file if you are done with the lifeboat"
  fi
elif have docker && [[ -n "$(docker ps -aq --filter "label=talos.cluster.name=${CLUSTER_NAME}" 2>/dev/null)" ]]; then
  # `-aq`, the same filter substrate_preflight uses (substrate/docker.sh), not
  # `-q`. With the node containers STOPPED — a laptop that was rebooted, a
  # `docker stop` — the running-only filter fell through to the port scan, found
  # every port free, and reported a machine that is ready to create. It is not:
  # preflight sees those containers with `-aq` and refuses. A go/no-go gate that
  # says "ready" and then a create that dies is the gate failing at its one job.
  if [[ -n "$(docker ps -q --filter "label=talos.cluster.name=${CLUSTER_NAME}" 2>/dev/null)" ]]; then
    ok "Cluster '${CLUSTER_NAME}' is already running — its ports are expected to be bound"
  else
    check_fail "Cluster '${CLUSTER_NAME}' containers exist but are STOPPED — ./scripts/create-cluster.sh refuses to create over them"
    echo "     Bring the existing cluster back:  docker start \$(docker ps -aq --filter label=talos.cluster.name=${CLUSTER_NAME})"
    echo "     Or start over:                    ./scripts/destroy-cluster.sh"
  fi
else
  # Every NODEPORT_* in versions.env, or preflight passes and the module that
  # needs the missed port fails at the venue instead. Plus port 80, which the
  # controlplane container publishes to NODEPORT_INGRESS — the only privileged
  # port the workshop binds, and what makes the hostnames work port-free here.
  ports=()
  while IFS= read -r port; do ports+=("${port}"); done < <(cloudbox_host_ports)
  # port_in_use (lib.sh), not a bare connect to 127.0.0.1. The cluster publishes
  # these on 0.0.0.0, and the connect probe only ever saw loopback: a listener
  # bound to this machine's LAN address alone answered nothing at 127.0.0.1, so
  # every port read "free" and the create then died on "bind: address already in
  # use" — the one failure this gate exists to predict. Port 80 is the one it
  # hurts most, being the only privileged port the workshop binds and the thing
  # that makes the hostnames work without a port.
  for port in "${ports[@]}"; do
    if port_in_use "${port}"; then
      check_fail "Port ${port} is already in use — the cluster needs it; free it first"
      holder="$(port_listeners "${port}")"
      [[ -n "${holder}" ]] && printf '     %s\n' "${holder}"
    else
      ok "Port ${port} is free"
    fi
  done
fi

# --- Hostname resolution --------------------------------------------------------
# Verify only. The block is written on the create path (create-cluster.sh) or by
# `--write-hosts`, which is where the sudo prompt belongs; --check never mutates.
step "Workshop hostnames (*.${CLOUDBOX_DOMAIN})"
if hosts_file_unreadable; then
  # Before every other question about this file, on every substrate: unreadable
  # is not absent. Every predicate below opens with `[[ -r ]] || return 0` and
  # would report a clean machine, while the writer refuses (rightly — it would
  # otherwise replace the whole file with the block alone) and tbx cannot be
  # told whether stale 127.0.0.1 lines are overriding its resolver.
  check_fail "${CLOUDBOX_HOSTS_FILE} exists but cannot be read from here, so nothing can tell whether the workshop names resolve — check its permissions (ls -l ${CLOUDBOX_HOSTS_FILE})"
elif [[ "${SUBSTRATE}" == "tbx" ]] && hosts_block_stale_for_tbx; then
  # "No entries needed" is true and useless when docker-substrate lines are still
  # sitting there: /etc/hosts is consulted BEFORE talos-box's resolver, so those
  # 127.0.0.1 lines win and every workshop URL reaches the attendee's own
  # loopback on a perfectly healthy cluster. substrate_preflight in
  # substrate/tbx.sh dies on exactly this predicate — a go/no-go gate that says
  # "ready" and then a create that dies is the gate failing at its one job.
  # The predicate is markers OR bare loopback lines: the entries are what break
  # tbx, and they routinely outlive the comments that marked them.
  check_fail "${CLOUDBOX_HOSTS_FILE} still points CloudBox names at 127.0.0.1, and on tbx those lines OVERRIDE talos-box's resolver"
  stale_lines="$(hosts_loopback_lines)"
  if [[ -n "${stale_lines}" ]]; then
    echo "     Delete these lines (line: text):"
    printf '     %s\n' "${stale_lines}"
  else
    echo "     (a CloudBox marker is present with no entries under it — delete the marker too)"
  fi
  echo "     Remove them:   ./scripts/destroy-cluster.sh   # if the docker cluster is still around"
  echo "                    sudo \$EDITOR ${CLOUDBOX_HOSTS_FILE}   # otherwise, by hand, markers included"
elif [[ "${SUBSTRATE}" == "tbx" ]]; then
  ok "tbx substrate — talos-box's resolver answers *.${CLOUDBOX_DOMAIN}; no ${CLOUDBOX_HOSTS_FILE} entries needed"
  info "  (verify after the cluster exists: tbx status ${CLUSTER_NAME})"
elif ! hosts_markers_paired; then
  # Before anything reads the names: an unpaired block is a file no script may
  # rewrite (lib.sh, assert_hosts_block_wellformed), so create-cluster.sh will
  # refuse to touch it. Reporting "the block is correct" — which a begin-only
  # block listing every name used to do — hides the one thing to fix.
  check_fail "${CLOUDBOX_HOSTS_FILE} has an unpaired CloudBox marker — the block must be exactly one '${CLOUDBOX_HOSTS_BEGIN}' … '${CLOUDBOX_HOSTS_END}' pair, in that order"
  echo "     Nothing will rewrite it in that state (the rewrite would delete every line after the begin marker)."
  echo "     Fix by hand: sudo \$EDITOR ${CLOUDBOX_HOSTS_FILE}   # then: ./scripts/install.sh --print-hosts"
elif hosts_block_present; then
  ok "${CLOUDBOX_HOSTS_FILE} has the CloudBox block ($(cloudbox_hostnames | wc -l | tr -d ' ') names)"
  # Entries right, prose stale: the block was written by an older copy of this
  # repo whose comment paragraph read differently. Nothing resolves any worse
  # for it, so this is a note and not a failure.
  hosts_block_text_current || info "  (the block's comment text is outdated — ./scripts/install.sh --write-hosts refreshes it)"
elif [[ -z "$(substrate_current)" ]]; then
  info "No cluster yet — ./scripts/create-cluster.sh writes the ${CLOUDBOX_HOSTS_FILE} block (asks for sudo once)"
  info "  Preview the lines: ./scripts/install.sh --print-hosts"
else
  # Captured once: hosts_missing_names greps ${CLOUDBOX_HOSTS_FILE} once per
  # name, and calling it twice in one message re-reads the file for a count it
  # already had — and could report a count and a list from two different reads.
  missing_names="$(hosts_missing_names)"
  if [[ -n "${missing_names}" ]]; then
    check_fail "${CLOUDBOX_HOSTS_FILE} is missing $(printf '%s\n' "${missing_names}" | wc -l | tr -d ' ') CloudBox name(s): $(printf '%s\n' "${missing_names}" | tr '\n' ' ')"
  else
    # Every name resolves and the block is STILL not what it should be: it
    # carries something extra — most often a name removed from
    # ${CLOUDBOX_EXTRA_HOSTS_FILE} whose 127.0.0.1 line is still in the block.
    # Only the whole-block comparison can see this direction of drift.
    check_fail "${CLOUDBOX_HOSTS_FILE}'s CloudBox block is not what it should be — every current name resolves, so it carries lines that no longer belong (a removed --add-hosts name, or a hand edit)"
  fi
  echo "     Fix: ./scripts/install.sh --write-hosts   # rewrites the block (sudo)"
  echo "     See: ./scripts/install.sh --print-hosts   # what belongs in it"
fi

# WSL2 throws /etc/hosts away. `generateHosts` defaults to true, so on every
# restart WSL regenerates the file from the Windows hosts file plus its own
# entries — and the CloudBox block, written on a previous boot, is simply gone.
# The cluster containers survive a restart; the names do not, so this looks like
# an ingress that broke overnight. Only worth saying on WSL2, and only when the
# generated header is there and our block is not.
if is_wsl2 \
   && [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] \
   && grep -qi 'automatically generated' "${CLOUDBOX_HOSTS_FILE}" \
   && ! hosts_block_present; then
  warn "This ${CLOUDBOX_HOSTS_FILE} is WSL-generated — WSL rewrites it from the Windows hosts file on every restart, which deletes the CloudBox block."
  info "  Keep it: add to /etc/wsl.conf, then 'wsl --shutdown' from Windows —"
  info "    [network]"
  info "    generateHosts = false"
  info "  Or re-run after each restart: ./scripts/install.sh --write-hosts"
fi

# --- Tools -----------------------------------------------------------------------
step "CLI tools (installed by ./scripts/dev-setup.sh)"

check_tool() {
  local name="$1" want="$2"; shift 2
  local out
  if ! have "${name}"; then
    check_fail "${name}: not found — run ./scripts/dev-setup.sh (then restart your shell)"
    return
  fi
  out="$("$@" 2>/dev/null | tr -s '\n\t' '  ' || true)"
  if [[ -z "${want}" ]]; then
    ok "${name}: $(echo "${out}" | cut -c1-80)"
  elif [[ "${out}" == *"${want}"* ]]; then
    ok "${name} ${want}"
  else
    check_fail "${name}: wrong version (want ${want}, got: $(echo "${out}" | cut -c1-60))"
  fi
}

check_tool talosctl "${TALOS_VERSION}"        talosctl version --client --short
check_tool kubectl  "v${KUBERNETES_VERSION}"  kubectl version --client
check_tool helm     ""                        helm version --short
check_tool kind     ""                        kind version
check_tool crane    ""                        crane version
check_tool cilium   ""                        cilium version --client
check_tool jq       ""                        jq --version

# --- Kubeconfig ---------------------------------------------------------------------
step "Kubeconfig (which cluster this laptop will talk to)"
# mise.toml pins KUBECONFIG to a workshop-only file for this repo, so the cluster
# lands somewhere that contains nothing else and a destroy leaves nothing to fall
# through to (docs/HAZARDS.md, "the workshop scripts ran against whatever cluster
# kubectl pointed at"). The pin only reaches you through mise — an activated shell,
# a mise shim, or `mise run`/`mise exec`. Not having it is a supported way to run
# the workshop; having it in one place and not the other is not, which is the only
# thing this section is really looking for.
kc_in_use="$(kubeconfig_in_use)"
if [[ "${kc_in_use}" == "${CLOUDBOX_KUBECONFIG}" ]]; then
  ok "workshop kubeconfig in effect: ${kc_in_use}"
  info "It holds this workshop's cluster and nothing else — that is deliberate."
elif workshop_cluster_is_elsewhere; then
  # Both halves exist and they disagree: a cluster was created with mise in the
  # picture, and this shell cannot see it. Nothing downstream can work.
  check_fail "your workshop cluster is in ${CLOUDBOX_KUBECONFIG}, but this shell reads ${kc_in_use} — the cluster is fine, this shell is looking in the wrong file"
  echo "     Fix it, do NOT rebuild:"
  echo "       export KUBECONFIG=${CLOUDBOX_KUBECONFIG}   # this shell"
  # shellcheck disable=SC2016  # deliberately printing an unexpanded snippet
  echo '       eval "$(mise activate bash)"'"                  # every shell (zsh/fish: mise docs)"
else
  warn "mise's kubeconfig pin is not in effect in this shell"
  info "Everything will land in ${kc_in_use} instead — supported, and exactly how"
  info "this workshop behaved before the pin existed. One thing to avoid: driving the"
  info "scripts through 'mise run' / 'mise exec' while typing bare commands in a shell"
  info "without the pin — then the cluster and your terminal are in two different files."
  info "Either stay consistent, or activate mise (see ./scripts/dev-setup.sh)."
fi

# --- Pre-pulled images --------------------------------------------------------------
step "Pre-pulled images (populated by ./scripts/cloudbox-init.sh)"

if [[ "${SUBSTRATE}" == "tbx" ]]; then
  # The raw disk image every VM boots from — asked of tbx itself where it can be
  # (`tbx cache list -o json`), and of the cache layout when it cannot
  # (tbx_cache_has_disk in lib.sh, which documents both).
  #
  # The ARCHITECTURE is half the question and used to be missing entirely: the
  # check globbed the version directory, and the cache is keyed
  # schematic/version/arch — so a disk pulled while the mirror was being filled
  # for the other architecture (an amd64 Colima daemon on an arm64 Mac) reported
  # "cached" for VMs that cannot execute it. The VMs are natively virtualised, so
  # their arch is the HOST CPU's: node_arch tbx / host_cpu_arch, which sees
  # through a Rosetta shell where uname -m does not.
  # Checked BEFORE the docker gate below: neither source needs the Docker daemon,
  # and on tbx the answer still matters on a laptop whose Docker is not up.
  tbx_disk_arch="$(node_arch tbx 2>/dev/null || true)"
  if [[ -z "${tbx_disk_arch}" ]]; then
    check_fail "could not determine this host's CPU architecture, so the cached Talos ${TALOS_VERSION} disk image cannot be checked against it (uname -m says '$(uname -m)')"
  elif tbx_cache_has_disk "${TALOS_VERSION}" "${tbx_disk_arch}"; then
    ok "Talos ${TALOS_VERSION} ${tbx_disk_arch} disk image is cached for tbx (${TBX_CACHE_SOURCE})"
  else
    check_fail "no complete Talos ${TALOS_VERSION} disk image for ${tbx_disk_arch} — your tbx VMs are ${tbx_disk_arch} and nothing usable is cached for them (checked via ${TBX_CACHE_SOURCE}; an interrupted pull leaves the version directory behind, empty). Run ./scripts/cloudbox-init.sh (needs the Image Factory, so do it at home)"
  fi
  # What the container-image checks below can and cannot say on tbx: the crane
  # mirror is a Docker container either way, so its content is verified the same
  # — but the container-side probe proves reachability from a DOCKER container,
  # not from the tbx VMs, which reach the same registry over the cluster gateway
  # (create-cluster.sh patches that in; tbx doctor covers the host networking).
  info "  (the container-image checks below speak for docker; the VMs reach the mirror via the cluster gateway)"
fi

if ! docker_running; then
  check_fail "Skipping image checks — Docker is not running"
else
  # Parse images.txt (same format as cloudbox-init.sh)
  section=""
  host_missing=0; mirror_missing=0; host_total=0; mirror_total=0
  mirror_arch_bad=0
  # The arch the mirror MUST hold: the one the nodes of the substrate this
  # machine will actually create on will run — `node_arch "${SUBSTRATE}"`, with
  # SUBSTRATE the already-resolved decision (no second `tbx doctor`).
  #
  # This used to be mirror_target_arch(), which keyed on the tbx BINARY, so a
  # laptop with tbx installed and a failing doctor had its mirror filled for
  # arm64 VMs and GRADED against arm64 VMs — while create-cluster.sh built
  # docker containers on an amd64 daemon and every pulled image was the wrong
  # architecture. Filling and grading now follow the same decision the create
  # follows (lib.sh, mirror_target_substrate), so the two cannot disagree.
  # Empty on failure: the arch checks then pass open rather than guess.
  mirror_arch="$(node_arch "${SUBSTRATE}" || true)"
  mirror_for="${SUBSTRATE}"
  # An amd64 Colima/Lima VM on an arm64 Mac is the case that made this worth
  # saying out loud: on tbx the mirror is arm64 (the VMs' arch) and the Docker
  # daemon next to it is amd64. Nothing is broken — the mirror is a container on
  # that daemon serving images to VMs — but it is a surprising pair to see.
  daemon_arch="$(docker_server_arch || true)"
  if [[ -n "${mirror_arch}" && -n "${daemon_arch}" && "${mirror_arch}" != "${daemon_arch}" ]]; then
    warn "The mirror serves ${mirror_arch} — the arch your ${mirror_for} nodes run — while this machine's Docker daemon is ${daemon_arch}. That is correct for ${mirror_for} (the mirror is a container on that daemon; the nodes are not). Change substrate and the mirror must be rebuilt: CLOUDBOX_SUBSTRATE=<the other one> ./scripts/cloudbox-init.sh"
  fi

  # Is the mirror registry up at all?
  if mirror_running && curl -fsS "http://localhost:${MIRROR_PORT}/v2/" >/dev/null 2>&1; then
    ok "Mirror registry '${MIRROR_NAME}' is running on localhost:${MIRROR_PORT}"
    mirror_up=true

    # The cluster NODES are containers — reaching the mirror from localhost
    # proves nothing about them. Probe from container context too (docker-ce
    # inside WSL2, for example, has no host.docker.internal).
    #
    # The probe image is the MIRROR'S OWN image (registry:3.1.1, on the [host]
    # list): the mirror container is running from it two lines above, so it is
    # provably in the local cache, and `--pull=never` guarantees this preflight
    # never reaches for a registry. It used to be busybox:1.37.0 — which is a
    # [mirror] image, copied into the registry by crane and therefore NEVER
    # pulled into the host Docker engine. Offline at the venue that pull fails
    # and the check reported "mirror not reachable from containers": a red
    # finding manufactured by the checker itself, on the one tool whose whole
    # job is to be trustworthy. (registry:3.1.1 is Alpine-based and carries the
    # same BusyBox 1.37.0 wget, so the probe command is unchanged.)
    mirror_ep="$(mirror_host_endpoint)"
    if [[ "${mirror_ep}" == "http://${TALOS_SUBNET_GATEWAY}:${MIRROR_PORT}" ]] && \
       ! docker network inspect "${CLUSTER_NAME}" >/dev/null 2>&1; then
      # Native Linux: the gateway address only exists once the cluster's
      # docker network does — nothing to probe yet, and nothing to fix.
      info "Container-side mirror probe skipped (${TALOS_SUBNET_GATEWAY} appears with the '${CLUSTER_NAME}' network)"
    elif ! docker image inspect "${MIRROR_IMAGE}" >/dev/null 2>&1; then
      # Nothing to probe WITH. Say so; do not count it as a mirror failure —
      # the missing image is the host-image check's finding, below.
      info "Container-side mirror probe skipped (${MIRROR_IMAGE} is not in the local Docker cache)"
    elif docker run --rm --pull=never --entrypoint wget "${MIRROR_IMAGE}" \
         -q -T 5 -O- "${mirror_ep}/v2/" >/dev/null 2>&1; then
      ok "Mirror reachable from containers at ${mirror_ep}"
    else
      check_fail "Mirror not reachable from containers at ${mirror_ep} — set CLOUDBOX_MIRROR_HOST to an address containers can reach (docker-ce in WSL2 has no host.docker.internal)"
    fi
  else
    check_fail "Mirror registry '${MIRROR_NAME}' is not running — run ./scripts/cloudbox-init.sh"
    mirror_up=false
  fi

  # check_mirror_image <repo-path-with-tag-or-digest>
  check_mirror_image() {
    local path="$1" repo ref
    if [[ "${path}" == *@sha256:* ]]; then
      repo="${path%%@*}"; repo="${repo%%:*}"   # strip digest, then any tag
      ref="sha256:${path##*@sha256:}"
    else
      repo="${path%%:*}"
      ref="${path##*:}"
    fi
    curl -fsS -o /dev/null \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
      "http://localhost:${MIRROR_PORT}/v2/${repo}/manifests/${ref}"
  }

  # check_mirror_arch <repo-path-with-tag> — tag-pinned mirror content is
  # copied for ONE architecture (cloudbox-init.sh uses crane --platform), and a
  # wrong-arch mirror is worse than a missing one: it still SERVES manifests,
  # so the cluster's registry fallback never triggers and pods crashloop with
  # exec-format errors — offline, at the venue. Fetch the tag's manifest,
  # follow its config blob, and compare .architecture to the Docker daemon's.
  # Index manifests (a mirror populated all-arch by an older cloudbox-init.sh)
  # carry every architecture and pass by construction. Every tag pin is
  # checked — a partially re-run mirror can mix architectures, so one
  # representative sample is not enough. Two localhost GETs per image, cheap.
  # Returns 1 only on a proven mismatch; indeterminate probes pass.
  # Repos in MIRROR_ARCH_EXEMPT (versions.env) are skipped at the call site:
  # intentionally single-arch images (Backstage) that run emulated would
  # otherwise fail every Apple Silicon attendee's preflight.
  mirror_arch_exempt() {
    case " ${MIRROR_ARCH_EXEMPT} " in
      *" ${1%%:*} "*) return 0 ;;
    esac
    return 1
  }
  check_mirror_arch() {
    local repo="${1%%:*}" ref="${1##*:}" manifest media cfg img_arch
    [[ -n "${mirror_arch}" ]] || return 0
    manifest="$(curl -fsS \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
      "http://localhost:${MIRROR_PORT}/v2/${repo}/manifests/${ref}" 2>/dev/null)" || return 0
    media="$(jq -r '.mediaType // ""' <<<"${manifest}")"
    [[ "${media}" == *image.index* || "${media}" == *manifest.list* ]] && return 0
    cfg="$(jq -r '.config.digest // ""' <<<"${manifest}")"
    [[ -z "${cfg}" ]] && return 0
    img_arch="$(curl -fsS "http://localhost:${MIRROR_PORT}/v2/${repo}/blobs/${cfg}" 2>/dev/null \
      | jq -r '.architecture // ""')" || return 0
    [[ -z "${img_arch}" || "${img_arch}" == "${mirror_arch}" ]]
  }

  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "${line}" | xargs)"
    [[ -z "${line}" ]] && continue
    case "${line}" in
      "[host]")   section="host"; continue ;;
      "[mirror]") section="mirror"; continue ;;
    esac
    if [[ "${section}" == "host" ]]; then
      host_total=$((host_total + 1))
      if docker image inspect "${line}" >/dev/null 2>&1; then
        :
      else
        fail "missing from Docker: ${line}"
        host_missing=$((host_missing + 1))
      fi
    elif [[ "${section}" == "mirror" && "${mirror_up}" == "true" ]]; then
      mirror_total=$((mirror_total + 1))
      mirror_path="$(strip_registry "${line}")"
      if ! check_mirror_image "${mirror_path}"; then
        fail "missing from mirror: ${line}"
        mirror_missing=$((mirror_missing + 1))
      elif [[ "${line}" != *@sha256:* ]] && ! mirror_arch_exempt "${mirror_path}" \
          && ! check_mirror_arch "${mirror_path}"; then
        fail "wrong architecture in mirror: ${line}"
        mirror_arch_bad=$((mirror_arch_bad + 1))
      fi
    fi
  done < "${SCRIPT_DIR}/images.txt"

  if [[ ${host_missing} -eq 0 ]]; then
    ok "Host images: ${host_total}/${host_total} present"
  else
    check_fail "Host images: $((host_total - host_missing))/${host_total} present — run ./scripts/cloudbox-init.sh"
  fi
  if [[ "${mirror_up}" == "true" ]]; then
    if [[ ${mirror_missing} -eq 0 ]]; then
      ok "Mirror images: ${mirror_total}/${mirror_total} present"
    else
      check_fail "Mirror images: $((mirror_total - mirror_missing))/${mirror_total} present — run ./scripts/cloudbox-init.sh"
    fi
    if [[ ${mirror_arch_bad} -gt 0 ]]; then
      check_fail "${mirror_arch_bad} mirror image(s) are for a different CPU architecture than your ${mirror_for} nodes run (${mirror_arch:-unknown}) — re-run ./scripts/cloudbox-init.sh on THIS machine"
    elif [[ -n "${mirror_arch}" && ${mirror_total} -gt 0 && ${mirror_missing} -eq 0 ]]; then
      ok "Mirror content matches the architecture your ${mirror_for} nodes run (${mirror_arch})"
    fi
  fi
fi

# --- Verdict -------------------------------------------------------------------------
echo
if [[ ${failures} -eq 0 ]]; then
  ok "All checks passed — you are ready for the workshop! 🎉"
  info "At the venue: ./scripts/create-cluster.sh"
  echo "   Forecast: cloudy, locally."
  exit 0
else
  fail "${failures} check(s) failed — fix the ❌ items above and re-run."
  info "No luck? The devcontainer/Codespaces path in the README is the lifeboat."
  exit 1
fi
