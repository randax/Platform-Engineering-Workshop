#!/usr/bin/env bash
# =============================================================================
# install.sh — CloudBox pre-flight check (step 3, the go/no-go gate)
#
# Checks that this machine can run the workshop. It only READS state —
# it never installs anything, never touches a cluster, never pulls images.
#
# Usage:
#   ./scripts/install.sh --check    # run the pre-flight check
#   ./scripts/install.sh            # same check + usage text
#   ./scripts/install.sh --print-hosts   # the /etc/hosts lines the docker substrate needs
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
# Read-only: substrate_resolve() only reads the override, the persisted file and
# `tbx doctor` — it never writes, so --check stays a check. Assigned before it is
# compared (lib.sh:231-240): a die() inside the command substitution would only
# kill the subshell if it were compared inline.
SUBSTRATE="$(substrate_resolve)"
info "Substrate: ${SUBSTRATE}"
if [[ "${SUBSTRATE}" == "docker" && -z "${CLOUDBOX_SUBSTRATE:-}" && -z "$(substrate_current)" ]]; then
  info "  (tbx not used: $(substrate_doctor_reason))"
fi
# The pin this laptop will actually run. check-consistency.sh check 10 only
# proves versions.env and mise.toml agree with each other — mise has no tbx
# backend to install from, so the binary on PATH is unasserted until here.
if [[ "${SUBSTRATE}" == "tbx" ]] && have tbx; then
  tbx_version_check check_fail
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
if [[ "${SUBSTRATE}" != "docker" ]]; then
  ok "tbx substrate — the workshop publishes no host ports at all"
  info "  (NodePorts live inside the VMs; the ingress is a LoadBalancer VIP on the cluster's own segment)"
elif have docker && [[ -n "$(docker ps -q --filter "label=talos.cluster.name=${CLUSTER_NAME}" 2>/dev/null)" ]]; then
  ok "Cluster '${CLUSTER_NAME}' is already running — its ports are expected to be bound"
else
  # Every NODEPORT_* in versions.env, or preflight passes and the module that
  # needs the missed port fails at the venue instead. Plus port 80, which the
  # controlplane container publishes to NODEPORT_INGRESS — the only privileged
  # port the workshop binds, and what makes the hostnames work port-free here.
  ports=("${NODEPORT_GITEA}" "${NODEPORT_ARGOCD}" "${NODEPORT_ZOT}" \
         "${NODEPORT_PORTAL}" "${NODEPORT_BACKSTAGE}" "${NODEPORT_RUSTFS_S3}" \
         "${NODEPORT_GRAFANA}" "${NODEPORT_KOURIER}" "${NODEPORT_NATS}" 80)
  for port in "${ports[@]}"; do
    if (echo > "/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      check_fail "Port ${port} is already in use — the cluster needs it; free it first (lsof -i :${port})"
    else
      ok "Port ${port} is free"
    fi
  done
fi

# --- Hostname resolution --------------------------------------------------------
# Verify only. The block is written on the create path (create-cluster.sh), which
# is where the one sudo prompt of the workshop belongs; --check never mutates.
step "Workshop hostnames (*.${CLOUDBOX_DOMAIN})"
if [[ "${SUBSTRATE}" == "tbx" ]]; then
  ok "tbx substrate — talos-box's resolver answers *.${CLOUDBOX_DOMAIN}; no ${CLOUDBOX_HOSTS_FILE} entries needed"
  info "  (verify after the cluster exists: tbx status ${CLUSTER_NAME})"
elif hosts_block_present; then
  ok "${CLOUDBOX_HOSTS_FILE} has the CloudBox block ($(cloudbox_hostnames | wc -l | tr -d ' ') names)"
elif [[ -z "$(substrate_current)" ]]; then
  info "No cluster yet — ./scripts/create-cluster.sh writes the ${CLOUDBOX_HOSTS_FILE} block (asks for sudo once)"
  info "  Preview the lines: ./scripts/install.sh --print-hosts"
else
  # Captured once: hosts_missing_names greps ${CLOUDBOX_HOSTS_FILE} once per
  # name, and calling it twice in one message re-reads the file for a count it
  # already had — and could report a count and a list from two different reads.
  missing_names="$(hosts_missing_names)"
  check_fail "${CLOUDBOX_HOSTS_FILE} is missing $(printf '%s\n' "${missing_names}" | wc -l | tr -d ' ') CloudBox name(s): $(printf '%s\n' "${missing_names}" | tr '\n' ' ')"
  echo "     Fix: ./scripts/install.sh --print-hosts   # then add them, or re-run create-cluster.sh"
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
  # The raw disk image every VM boots from. Nested by schematic/version/arch
  # (upstream docs/SPEC.md:110-113), so match on the version DIRECTORY rather
  # than guessing the schematic id — ours is talos-box's own default — but
  # assert the FILE inside it: Cache.Ensure MkdirAll's that directory before it
  # downloads anything (upstream internal/imagecache/cache.go:163-168), so an
  # interrupted `tbx cache pull` leaves the directory there with no disk.raw
  # (upstream calls that state Entry.Incomplete, cache.go:63-67) and a
  # directory-only check would call it cached. disk.raw is published by
  # temp-file-plus-rename (cache.go:393-417), so its presence means complete.
  # The *disk.raw glob also covers the legacy <version>/disk.raw layout.
  # Checked BEFORE the docker gate below: it is a plain filesystem lookup, and
  # on tbx the answer still matters on a laptop whose Docker is not up.
  if find "${HOME}/.talosbox/cache" -type f -path "*/${TALOS_VERSION}/*disk.raw" -size +0c 2>/dev/null | grep -q .; then
    ok "Talos ${TALOS_VERSION} disk image is cached for tbx"
  else
    check_fail "no complete Talos ${TALOS_VERSION} disk.raw in ~/.talosbox/cache (an interrupted pull leaves the version directory behind, empty) — run ./scripts/cloudbox-init.sh (needs the Image Factory, so do it at home)"
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
  # The DAEMON's arch — what the node containers run — not uname -m (an x86_64
  # Rosetta shell on Apple Silicon reports the wrong one). Empty on failure:
  # the arch checks then pass open rather than guessing.
  mirror_arch="$(docker_server_arch || true)"

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
      check_fail "${mirror_arch_bad} mirror image(s) are for a different CPU architecture than Docker runs (${mirror_arch:-unknown}) — re-run ./scripts/cloudbox-init.sh on THIS machine"
    elif [[ -n "${mirror_arch}" && ${mirror_total} -gt 0 && ${mirror_missing} -eq 0 ]]; then
      ok "Mirror content matches Docker's architecture (${mirror_arch})"
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
