#!/usr/bin/env bash
# =============================================================================
# cloudbox-init.sh — pre-pull all workshop images (step 2, run AT HOME)
#
# Downloads every pinned image from scripts/images.txt so the workshop needs
# no image downloads on conference WiFi:
#
#   [host] images   -> pulled into your local Docker engine (docker pull)
#   [mirror] images -> copied into a local registry container that the cluster
#                      nodes use as a pull-through mirror
#
# Why the mirror? The Talos nodes are Docker containers with their OWN
# containerd inside — your host Docker image cache is invisible to them.
# So we run a plain OCI registry ("cloudbox-mirror", localhost:5001, images
# stored in a persistent Docker volume) and copy every cluster image into it,
# preserving repository paths and digests (via crane, so digest-pinned images
# stay valid). create-cluster.sh then points the Talos machine config
# registry mirrors at it, with automatic fallback to the real registries.
#
# Usage:
#   ./scripts/cloudbox-init.sh          # pull + mirror everything
#   ./scripts/cloudbox-init.sh --yes    # skip the size confirmation
#
# Expect ~15–20 GB of downloads. Run this at home, not at the venue!
# Safe to re-run: already-present images are skipped quickly.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

ASSUME_YES="false"
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES="true"

need docker "Install Docker Desktop / OrbStack / docker-ce first."
docker_running || die "Docker daemon is not reachable. Start Docker and re-run."
need crane

IMAGES_FILE="${SCRIPT_DIR}/images.txt"
[[ -f "${IMAGES_FILE}" ]] || die "Missing ${IMAGES_FILE}"

# --- Parse images.txt into the two sections -----------------------------------
host_images=()
mirror_images=()
section=""
while IFS= read -r line; do
  line="${line%%#*}"                      # strip comments
  line="$(echo "${line}" | xargs)"        # trim whitespace
  [[ -z "${line}" ]] && continue
  case "${line}" in
    "[host]")   section="host" ;;
    "[mirror]") section="mirror" ;;
    *)
      case "${section}" in
        host)   host_images+=("${line}") ;;
        mirror) mirror_images+=("${line}") ;;
        *) die "images.txt: image '${line}' appears before a [host]/[mirror] section header" ;;
      esac
      ;;
  esac
done < "${IMAGES_FILE}"

total=$(( ${#host_images[@]} + ${#mirror_images[@]} ))

step "CloudBox image pre-pull"
echo "  ${#host_images[@]} host images + ${#mirror_images[@]} cluster images = ${total} total"
warn "This downloads roughly 15–20 GB. Make sure you have ${MIN_DISK_FREE_GB} GB free disk"
warn "and are on a good connection (home/office — NOT conference WiFi)."
if [[ "${ASSUME_YES}" != "true" ]]; then
  confirm "Continue?" || die "Aborted."
fi

# --- 1. Host images -------------------------------------------------------------
step "Pulling host images into Docker"
i=0
for image in "${host_images[@]}"; do
  i=$((i + 1))
  echo "  [${i}/${#host_images[@]}] ${image}"
  docker pull --quiet "${image}"
done
ok "Host images present"

# --- 2. Start the local mirror registry ------------------------------------------
step "Starting the '${MIRROR_NAME}' registry (localhost:${MIRROR_PORT})"
if mirror_running; then
  ok "Mirror already running"
elif docker inspect "${MIRROR_NAME}" >/dev/null 2>&1; then
  docker start "${MIRROR_NAME}" >/dev/null
  ok "Mirror container restarted"
else
  docker volume create "${MIRROR_VOLUME}" >/dev/null
  docker run -d \
    --name "${MIRROR_NAME}" \
    --restart unless-stopped \
    -p "${MIRROR_PORT}:5000" \
    -v "${MIRROR_VOLUME}:/var/lib/registry" \
    "${MIRROR_IMAGE}" >/dev/null
  ok "Mirror started (data persisted in Docker volume '${MIRROR_VOLUME}')"
fi

# Wait until the registry answers.
for _ in $(seq 1 30); do
  curl -fsS "http://localhost:${MIRROR_PORT}/v2/" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://localhost:${MIRROR_PORT}/v2/" >/dev/null 2>&1 \
  || die "Mirror registry did not become ready on localhost:${MIRROR_PORT}"

# --- 3. Copy cluster images into the mirror ----------------------------------------
# crane copies manifests byte-for-byte (digests preserved, all architectures),
# which `docker pull && docker push` would break for digest-pinned images.
step "Copying cluster images into the mirror (crane, digests preserved)"
i=0
failed=()
for image in "${mirror_images[@]}"; do
  i=$((i + 1))
  path="$(strip_registry "${image}")"
  dest="localhost:${MIRROR_PORT}/${path%%@*}"   # crane derives no tag from digests;
  [[ "${path}" == *@sha256:* && "${path}" != *:*@* ]] && dest="${dest}:pinned"
  echo "  [${i}/${#mirror_images[@]}] ${image}"
  if ! crane copy --insecure "${image}" "${dest}" >/dev/null 2>&1; then
    fail "      copy failed: ${image}"
    failed+=("${image}")
  fi
done

echo
if [[ ${#failed[@]} -gt 0 ]]; then
  fail "${#failed[@]} image(s) failed to copy:"
  printf '   %s\n' "${failed[@]}"
  die "Re-run this script to retry (already-copied images are fast)."
fi

ok "All ${total} images pre-pulled. The mirror survives reboots and cluster rebuilds."
info "Next: ./scripts/install.sh --check"
