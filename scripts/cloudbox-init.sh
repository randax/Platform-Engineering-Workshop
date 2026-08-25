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
# Expect ~7.5 GB of downloads on arm64, ~7.7 GB on amd64 (compressed layer
# bytes, measured 2026-08-11 against the pinned refs in images.txt).
# Cluster images are mirrored for THIS machine's CPU architecture only; the
# refs pinned by digest still carry every architecture, and are most of what
# is left (see the copy loop below for why that is not optional).
# Run this at home, not at the venue!
# Safe to re-run: already-present images are skipped quickly. Note: the
# registry never garbage-collects, so re-running over a mirror populated by an
# older all-arch run keeps the old blobs — delete the Docker volume
# (docker volume rm cloudbox-mirror-data) first to reclaim that space.
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

# The platform the cluster nodes actually run. The Talos "nodes" are containers
# on THIS host's Docker engine, so their CPU architecture is the DAEMON's — and
# that is what this must read, not uname -m: an x86_64 Rosetta shell on Apple
# Silicon (or a context pointing at a remote daemon) would otherwise mirror
# amd64 images for arm64 node containers, and install.sh --check — which
# compares the mirror against the same daemon arch — would flag the mirror this
# script had just built. Nothing here may be hard-coded (CI runs amd64, most
# laptops in the room are arm64).
node_arch="$(docker_server_arch)" \
  || die "Docker reports an unsupported architecture '$(docker version -f '{{.Server.Arch}}' 2>/dev/null)' — the workshop needs amd64 or arm64."
NODE_PLATFORM="linux/${node_arch}"

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
echo "  cluster images are mirrored for ${NODE_PLATFORM} (digest-pinned refs keep every architecture)"
warn "This downloads ~7.5 GB (arm64) / ~7.7 GB (amd64). Make sure you have ${MIN_DISK_FREE_GB} GB free disk"
warn "and are on a good connection (home/office — NOT conference WiFi)."
if [[ "${ASSUME_YES}" != "true" ]]; then
  confirm "Continue?" || die "Aborted."
fi

# --- 0. Preflight: every ref must exist upstream ---------------------------------
# `crane manifest` is a cheap API call per ref — a missing image should cost
# seconds here, not surface hours into a 7.5 GB pull.
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
# Registries drop connections. This is a ~7.5 GB download on somebody's home
# wifi, and a single transient blob failure used to abort the whole prework run
# — the 2026-08-17 rehearsal lost one at image 9 of 63. Retry with backoff
# before giving up on any one image; a genuinely missing image still fails, it
# just takes three attempts to say so.
retry() { # retry <attempts> <what> -- <cmd...>
  local attempts="$1" what="$2"; shift 3
  local n=1
  while true; do
    "$@" && return 0
    if [[ "${n}" -ge "${attempts}" ]]; then return 1; fi
    warn "      ${what} failed (attempt ${n}/${attempts}) — retrying in $((n * 5))s"
    sleep $((n * 5))
    n=$((n + 1))
  done
}

for image in "${host_images[@]}"; do
  i=$((i + 1))
  echo "  [${i}/${#host_images[@]}] ${image}"
  retry 3 "docker pull" -- docker pull --quiet "${image}" \
    || die "could not pull ${image} after 3 attempts — check your connection and re-run (already-pulled images are skipped)"
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
# crane is used instead of `docker pull && docker push` because it copies
# manifests byte-for-byte, so digest-pinned refs stay valid inside the mirror.
#
# Which architectures get copied is decided per ref, and both branches matter:
#
#   TAG-ONLY refs are copied for ${NODE_PLATFORM} only.
#     Without --platform, crane copies the WHOLE manifest index — s390x,
#     ppc64le, riscv64, 386, arm/v7 and the other of amd64/arm64 — none of
#     which this laptop can execute. That was about half the pre-pull:
#     registry.k8s.io/pause is 0.3 MB for one platform and 573 MB as a full
#     index. Deleting the --platform flag breaks nothing visibly; it just
#     doubles the download. Do not delete it.
#
#     --platform filters INDEX manifests only: a bare single-arch manifest
#     (e.g. the amd64-only Backstage image) is copied as-is, whatever its
#     architecture. This is a size optimization, not an architecture
#     validation — install.sh --check is what validates the mirror's arch.
#
#   DIGEST-PINNED refs (…@sha256:…) are copied whole, every architecture.
#     For a multi-arch image the pinned digest is the digest of the INDEX.
#     `crane copy --platform` stores only the child manifest, under a
#     different digest, so the index digest would not exist in the mirror —
#     a Talos node asking for …@sha256:<index> gets a 404 and, because
#     create-cluster.sh sets skipFallback: false, silently pulls from the
#     internet instead. That works at home and hangs on conference WiFi,
#     which is the exact failure this script exists to prevent. The foreign
#     architectures those refs drag along are the price of the offline
#     guarantee; the alternative (push the original index but only the one
#     child's blobs) was tested and rejected — containerd 2.x fetches every
#     child manifest in an index regardless of platform and errors out on the
#     missing ones.
#
# If --platform copy fails (an index with no manifest for this architecture),
# fall back to copying everything: fatter, but never a missing image offline.
step "Copying cluster images into the mirror (crane, ${NODE_PLATFORM} + pinned indexes)"
CRANE_LOG="$(mktemp)"
trap 'rm -f "${CRANE_LOG}"' EXIT
# The redirects belong on the COMMAND, not on the retry() wrapper: retry() reports
# each failed attempt with warn(), which writes to stdout, so wrapping the whole
# call in `>/dev/null` sent the "retrying in 5s" line to /dev/null too. The run
# then just appeared to freeze for 15 s on one image — on 63 of the 66 refs, i.e.
# on every path where the retry actually matters.
crane_copy() { crane copy "$@" >/dev/null 2>"${CRANE_LOG}"; }
i=0
failed=()
for image in "${mirror_images[@]}"; do
  i=$((i + 1))
  path="$(strip_registry "${image}")"
  dest="localhost:${MIRROR_PORT}/${path%%@*}"   # crane derives no tag from digests;
  [[ "${path}" == *@sha256:* && "${path}" != *:*@* ]] && dest="${dest}:pinned"

  copy_args=(--insecure)
  if [[ "${image}" == *@sha256:* ]]; then
    echo "  [${i}/${#mirror_images[@]}] ${image} (full index — digest-pinned)"
  else
    copy_args+=(--platform "${NODE_PLATFORM}")
    echo "  [${i}/${#mirror_images[@]}] ${image}"
  fi

  if retry 3 "crane copy" -- crane_copy "${copy_args[@]}" "${image}" "${dest}"; then
    continue
  fi
  if [[ ${#copy_args[@]} -gt 1 ]] \
     && retry 3 "crane copy (all arch)" -- crane_copy --insecure "${image}" "${dest}"; then
    warn "      no ${NODE_PLATFORM} manifest — copied every architecture instead"
    continue
  fi
  fail "      copy failed: ${image}"
  tail -n 3 "${CRANE_LOG}" | sed 's/^/      | /'
  failed+=("${image}")
done

echo
if [[ ${#failed[@]} -gt 0 ]]; then
  fail "${#failed[@]} image(s) failed to copy:"
  printf '   %s\n' "${failed[@]}"
  die "Re-run this script to retry (already-copied images are fast)."
fi

ok "All ${total} images pre-pulled. The mirror survives reboots and cluster rebuilds."

# ollama_bind_check — warn when Ollama listens on loopback only and the cluster
# is going to reach it from OUTSIDE the host's loopback.
#
# kagent's ModelConfig points at ${gateway}:11434, where the gateway is
# host.docker.internal on docker/macOS (Docker Desktop maps that to the host's
# loopback, so a 127.0.0.1-bound Ollama answers) but 172.30.<n>.1 on tbx — a
# real vmnet address on the host. Ollama's default bind is 127.0.0.1:11434, so a
# connection to 172.30.<n>.1:11434 is REFUSED, which surfaces in module 10 as an
# agent that never answers rather than as a bind problem.
#
# Warns, never dies: the model is optional, module 10 is a stretch module, and
# this runs during prework where dying would block the image pre-pull everyone
# needs. Probing 127.0.0.1 says whether Ollama is up at all; the LISTEN address
# says whether anything other than this host can reach it.
ollama_bind_check() {
  if [[ "${SUBSTRATE}" == "docker" ]]; then return 0; fi
  have curl || return 0
  if ! curl -fsS --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    info "Ollama is not serving on 127.0.0.1:11434 right now — start it before module 10."
    return 0
  fi
  local listen=""
  if have lsof; then
    listen="$(lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null || true)"
  elif have ss; then
    listen="$(ss -ltn 2>/dev/null | grep ':11434' || true)"
  fi
  # No tool to ask with: say nothing rather than guess.
  [[ -n "${listen}" ]] || return 0
  # Not loopback-only as soon as ONE listen address is a wildcard.
  if printf '%s\n' "${listen}" | grep -qE '(\*|0\.0\.0\.0|\[::\]):11434'; then
    ok "Ollama listens on all interfaces — the tbx VMs can reach it at <cluster-gateway>:11434."
    return 0
  fi
  warn "Ollama is bound to loopback only (127.0.0.1:11434). On the tbx substrate the"
  warn "cluster reaches the host at 172.30.<n>.1, and that connection will be REFUSED —"
  warn "module 10's kagent agent then hangs instead of answering. Fix it before the venue:"
  warn "  macOS:  launchctl setenv OLLAMA_HOST 0.0.0.0   # then quit and reopen Ollama.app"
  warn "  either: OLLAMA_HOST=0.0.0.0 ollama serve       # if you run it in a terminal"
}

# The substrate this machine will use — resolved ONCE here because both section
# 4 (Ollama's bind address is a tbx problem) and section 5 (the Talos disk cache
# is a tbx-only artefact) need it. Assigned before it is compared: a die() inside
# `[[ "$(substrate_resolve)" == … ]]` would only kill the subshell (lib.sh).
SUBSTRATE="$(substrate_resolve)"

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
  ollama_bind_check
fi

# --- 5. Talos disk image for the tbx substrate ---------------------------------
# The crane mirror above covers CONTAINER images. The tbx substrate also needs
# the Talos RAW DISK IMAGE, which talos-box downloads from the Image Factory and
# decompresses into ~/.talosbox/cache/ — 95 MB on arm64, 204 MB on amd64
# (measured). That download is Factory-side and cannot go through our mirror, so
# it must happen at home like everything else.
#
# --talos-version pins one ad-hoc combination (cmd/tbx/cache_pull.go:23,39-44):
# naming it deliberately skips the file-driven mode that would ALSO warm tbx's
# own registry mirror. Adopting that mirror is a spec non-goal — the crane
# mirror on localhost:${MIRROR_PORT} stays the single container-image store.
# Note this is IN ADDITION to everything above: a tbx attendee still needs Docker
# running for prework, because the crane mirror the VMs pull from is itself a
# Docker container. tbx replaces the NODES, not the mirror.
if [[ "${SUBSTRATE}" == "tbx" ]]; then
  if ! have tbx; then
    # Only reachable via CLOUDBOX_SUBSTRATE=tbx on a machine without the binary:
    # substrate_resolve's detection path requires `tbx doctor` to pass first.
    warn "substrate is 'tbx' but the tbx binary is not installed — cannot pre-pull"
    warn "the Talos disk image. Install tbx (see ./scripts/dev-setup.sh) and re-run."
    tbx_cached="skipped"
    tbx_doctor="skipped"
  else
    step "Pre-pulling the Talos ${TALOS_VERSION} disk image for tbx"
    if tbx cache pull --talos-version "${TALOS_VERSION}"; then
      ok "Talos disk image cached in ~/.talosbox/cache"
      tbx_cached="yes"
    else
      warn "'tbx cache pull --talos-version ${TALOS_VERSION}' failed — the first"
      warn "create will download it, which needs the Image Factory. Retry at home."
      tbx_cached="no"
    fi
    step "Checking the tbx host setup"
    if tbx doctor; then
      ok "tbx doctor passes"
      tbx_doctor="pass"
    else
      warn "tbx doctor reports problems (above). Fix them, or use the docker"
      warn "substrate: CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh"
      tbx_doctor="fail"
    fi
  fi
  info "Prework summary: images=${total} mirrored · talos-disk=${tbx_cached} · tbx-doctor=${tbx_doctor}"
else
  info "Prework summary: images=${total} mirrored · substrate=docker (no Talos disk image needed)"
fi

info "Next: ./scripts/install.sh --check"
