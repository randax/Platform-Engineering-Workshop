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
#   ./scripts/cloudbox-init.sh                    # pull + mirror everything
#   ./scripts/cloudbox-init.sh --yes              # skip the size confirmation
#   ./scripts/cloudbox-init.sh --skip-model-pull  # do not pull the optional Ollama model
#   ./scripts/cloudbox-init.sh -y --skip-model-pull
#
# Expect ~15–20 GB of downloads. Run this at home, not at the venue!
# Safe to re-run: already-present images are skipped quickly.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

ASSUME_YES="false"
SKIP_MODEL_PULL="false"
for arg in "$@"; do
  case "${arg}" in
    --yes|-y) ASSUME_YES="true" ;;
    --skip-model-pull) SKIP_MODEL_PULL="true" ;;
    *) die "Unknown argument '${arg}'. Usage: $0 [--yes|-y] [--skip-model-pull]" ;;
  esac
done

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

# --- 0. Preflight: every ref must exist upstream ---------------------------------
# `crane manifest` is a cheap API call per ref — a missing image should cost
# seconds here, not surface 15 GB into a multi-hour pull.
step "Preflight: checking that all ${total} refs exist upstream"
missing=()
for image in "${host_images[@]}" "${mirror_images[@]}"; do
  crane manifest "${image}" >/dev/null 2>&1 || missing+=("${image}")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  fail "${#missing[@]} image(s) do not exist upstream:"
  for image in "${missing[@]}"; do
    case "${image}" in
      ghcr.io/randax/*) echo "   ${image}   (not published yet — see issue #7)" ;;
      *)                echo "   ${image}" ;;
    esac
  done
  die "Nothing was downloaded. Fix scripts/images.txt (or publish the missing images) and re-run."
fi
ok "All ${total} refs resolve upstream"

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
CRANE_LOG="$(mktemp)"
trap 'rm -f "${CRANE_LOG}"' EXIT
i=0
failed=()
for image in "${mirror_images[@]}"; do
  i=$((i + 1))
  path="$(strip_registry "${image}")"
  dest="localhost:${MIRROR_PORT}/${path%%@*}"   # crane derives no tag from digests;
  [[ "${path}" == *@sha256:* && "${path}" != *:*@* ]] && dest="${dest}:pinned"
  echo "  [${i}/${#mirror_images[@]}] ${image}"
  if ! crane copy --insecure "${image}" "${dest}" >/dev/null 2>"${CRANE_LOG}"; then
    fail "      copy failed: ${image}"
    tail -n 3 "${CRANE_LOG}" | sed 's/^/      | /'
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

# --- 4. Pull the optional host-side model used by kagent ----------------------
if [[ "${SKIP_MODEL_PULL}" == "true" ]]; then
  info "Model pull skipped (--skip-model-pull). Before enabling kagent, run: ollama pull ${KAGENT_OLLAMA_MODEL}"
elif ! have ollama; then
  warn "'ollama' not found. Kagent's default ModelConfig needs ${KAGENT_OLLAMA_MODEL} pulled on the host. Install it from https://ollama.com."
  warn "On minimum-spec machines, --skip-model-pull silences this optional warning."
else
  step "Pulling host-side Ollama model for kagent (${KAGENT_OLLAMA_MODEL})"
  if ollama pull "${KAGENT_OLLAMA_MODEL}"; then
    ok "Host-side Ollama model ${KAGENT_OLLAMA_MODEL} is ready for kagent."
  else
    warn "Ollama could not pull ${KAGENT_OLLAMA_MODEL}; the image pre-pull completed successfully."
    warn "Re-run ./scripts/cloudbox-init.sh --skip-model-pull to finish without it, or fix Ollama and re-run."
  fi
fi

info "Next: ./scripts/install.sh --check"
