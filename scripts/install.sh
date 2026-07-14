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
#
# Checked:
#   * CPU architecture (amd64/arm64) and WSL2 hints
#   * Docker daemon reachable; CPUs/RAM allocatable to Docker; free disk
#   * Required CLI tools present at the pinned versions
#   * Pre-pulled images from scripts/images.txt (host cache + mirror registry)
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
  "") usage; echo ;;
  -h|--help) usage; exit 0 ;;
  *) usage; die "Unknown argument: $1 (this script only checks; it installs nothing)" ;;
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

# --- Docker ---------------------------------------------------------------------
if ! have docker; then
  check_fail "docker CLI not found — install Docker Desktop, OrbStack or docker-ce"
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
step "Workshop NodePorts free on the host"
if have docker && [[ -n "$(docker ps -q --filter "label=talos.cluster.name=${CLUSTER_NAME}" 2>/dev/null)" ]]; then
  ok "Cluster '${CLUSTER_NAME}' is already running — its ports are expected to be bound"
else
  for port in "${NODEPORT_GITEA}" "${NODEPORT_ARGOCD}" "${NODEPORT_ZOT}" \
              "${NODEPORT_PORTAL}" "${NODEPORT_BACKSTAGE}" "${NODEPORT_RUSTFS_S3}" \
              "${NODEPORT_KOURIER}"; do
    if (echo > "/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      check_fail "Port ${port} is already in use — the cluster needs it; free it first (lsof -i :${port})"
    else
      ok "Port ${port} is free"
    fi
  done
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

# --- Pre-pulled images --------------------------------------------------------------
step "Pre-pulled images (populated by ./scripts/cloudbox-init.sh)"

if ! docker_running; then
  check_fail "Skipping image checks — Docker is not running"
else
  # Parse images.txt (same format as cloudbox-init.sh)
  section=""
  host_missing=0; mirror_missing=0; host_total=0; mirror_total=0

  # Is the mirror registry up at all?
  if mirror_running && curl -fsS "http://localhost:${MIRROR_PORT}/v2/" >/dev/null 2>&1; then
    ok "Mirror registry '${MIRROR_NAME}' is running on localhost:${MIRROR_PORT}"
    mirror_up=true

    # The cluster NODES are containers — reaching the mirror from localhost
    # proves nothing about them. Probe from container context too (docker-ce
    # inside WSL2, for example, has no host.docker.internal).
    mirror_ep="$(mirror_host_endpoint)"
    if [[ "${mirror_ep}" == "http://${TALOS_SUBNET_GATEWAY}:${MIRROR_PORT}" ]] && \
       ! docker network inspect "${CLUSTER_NAME}" >/dev/null 2>&1; then
      # Native Linux: the gateway address only exists once the cluster's
      # docker network does — nothing to probe yet, and nothing to fix.
      info "Container-side mirror probe skipped (${TALOS_SUBNET_GATEWAY} appears with the '${CLUSTER_NAME}' network)"
    elif docker run --rm "docker.io/library/busybox:1.37.0" \
         wget -q -T 5 -O- "${mirror_ep}/v2/" >/dev/null 2>&1; then
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
      if ! check_mirror_image "$(strip_registry "${line}")"; then
        fail "missing from mirror: ${line}"
        mirror_missing=$((mirror_missing + 1))
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
