#!/usr/bin/env bash
# Module 00 — pre-flight verification. Safe to run any number of times.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Published minimums (MIN_DISK_FREE_GB, …) come from the single pin source.
# shellcheck source=../../scripts/versions.env
source "$REPO_ROOT/scripts/versions.env"
FAILED=0

ok()   { echo "✅ $1"; }
fail() { echo "❌ FAIL: $1"; FAILED=$((FAILED + 1)); }

# --- Substrate -------------------------------------------------------------
# Which substrate this laptop will use: real Talos VMs via talos-box (tbx) or
# Talos-in-Docker. This MUST agree with substrate_resolve() (scripts/lib.sh),
# which install.sh --check and create-cluster.sh use — a lab 00 that demanded
# tbx while create-cluster.sh built docker would fail an attendee who is
# perfectly ready. So the precedence below is theirs, in order:
#   1. CLOUDBOX_SUBSTRATE in the environment (the documented escape hatch)
#   2. the persisted answer from a previous create (~/.cloudbox/substrate)
#   3. CLOUDBOX_SUBSTRATE_DEFAULT=docker — the go-live gate's kill switch:
#      when the pin says docker, detection never upgrades to tbx
#   4. detection: `tbx doctor`
# Inlined rather than sourced, deliberately: scripts/lib.sh defines its own
# non-counting ok()/fail() (which would silently clobber the counting ones
# above — the trap lab/01-cluster/verify.sh records) and its need()/die() exit
# the process, which a checklist that must run every check may never do.
# Whenever substrate_resolve() changes, change this with it.

# `tbx doctor` is the slowest thing in this file (it probes the helper, DNS,
# routes and the mirror), and both the detection above and the tbx branch below
# want its answer — so run it at most once.
TBX_DOCTOR_RC=""
tbx_doctor_ok() {
  if [ -z "$TBX_DOCTOR_RC" ]; then
    if command -v tbx >/dev/null 2>&1 && tbx doctor >/dev/null 2>&1; then
      TBX_DOCTOR_RC=0
    else
      TBX_DOCTOR_RC=1
    fi
  fi
  return "$TBX_DOCTOR_RC"
}

SUBSTRATE="${CLOUDBOX_SUBSTRATE:-}"
if [ -z "$SUBSTRATE" ] && [ -r "$HOME/.cloudbox/substrate" ]; then
  SUBSTRATE="$(tr -d '[:space:]' < "$HOME/.cloudbox/substrate")"
fi
case "$SUBSTRATE" in
  tbx|docker) ;;
  *)
    if [ "${CLOUDBOX_SUBSTRATE_DEFAULT:-tbx}" = docker ]; then
      SUBSTRATE=docker
    elif tbx_doctor_ok; then
      SUBSTRATE=tbx
    else
      SUBSTRATE=docker
    fi
    ;;
esac
ok "substrate: $SUBSTRATE"

# --- Docker daemon ---------------------------------------------------------
# Unconditional on both substrates: the crane image mirror is a Docker
# container even when the cluster nodes are VMs. Only the docker substrate
# stops here, though — on tbx the host memory, `tbx doctor` and the cached
# Talos disk image are all still answerable with Docker down, and an attendee
# whose Docker is asleep deserves the whole picture rather than one line
# (scripts/install.sh takes the same view for the tbx image cache check).
if docker info >/dev/null 2>&1; then
  ok "Docker daemon is running"
else
  fail "Docker daemon not reachable — start Docker Desktop / the docker service, then re-run (the image mirror is a container on both substrates)"
  if [ "$SUBSTRATE" = docker ]; then
    echo "Cannot continue without Docker."
    exit 1
  fi
fi

# --- Machine resources -----------------------------------------------------
# The one resource question that cannot be substrate-blind: on docker what
# matters is the slice Docker itself was given, on tbx it is the HOST's memory,
# because the VMs take theirs from the host directly.
if [ "$SUBSTRATE" = docker ]; then
  # --- Docker memory -------------------------------------------------------
  MEM_BYTES="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  MEM_GB=$((MEM_BYTES / 1024 / 1024 / 1024))
  if [ "$MEM_GB" -ge "$MIN_DOCKER_MEMORY_GB" ]; then
    ok "Docker can use ${MEM_GB} GB memory (need >= ${MIN_DOCKER_MEMORY_GB})"
  else
    fail "Docker only has ${MEM_GB} GB memory — raise it to >= ${MIN_DOCKER_MEMORY_GB} GB (Docker Desktop: Settings > Resources; WSL2: .wslconfig)"
  fi

  # --- Docker CPUs ---------------------------------------------------------
  CPUS="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
  if [ "$CPUS" -ge "$MIN_CPUS" ]; then
    ok "Docker can use ${CPUS} CPUs (need >= ${MIN_CPUS})"
  else
    fail "Docker only has ${CPUS} CPUs — give it at least ${MIN_CPUS}"
  fi
else
  # tbx runs real VMs, so what matters is HOST memory, not Docker's slice. The
  # published floor is 16 GB (upstream talos-box asks for it too, docs/SPEC.md:27).
  if [ "$(uname -s)" = Darwin ]; then
    HOST_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
  else
    HOST_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 / 1024 ))
  fi
  if [ "${HOST_GB:-0}" -ge 16 ]; then
    ok "host memory: ${HOST_GB} GB (need >= 16 for the VM substrate)"
  else
    fail "host memory: ${HOST_GB:-0} GB — the tbx substrate needs >= 16 GB. Use the docker substrate instead: CLOUDBOX_SUBSTRATE=docker"
  fi
  # Memoised: on the detection path doctor has already run, and this reuses that
  # exit code instead of paying for a second probe.
  if tbx_doctor_ok; then
    ok "tbx doctor passes"
  else
    fail "tbx doctor reports problems — run 'tbx doctor' to see them (install with 'brew install randax/tap/tbx' + 'sudo tbx system install'), or use CLOUDBOX_SUBSTRATE=docker"
  fi
fi

# --- Free disk -------------------------------------------------------------
FREE_GB="$(df -Pk "$REPO_ROOT" | awk 'NR==2 {print int($4/1024/1024)}')"
if [ "${FREE_GB:-0}" -ge "$MIN_DISK_FREE_GB" ]; then
  ok "${FREE_GB} GB free disk (need >= ${MIN_DISK_FREE_GB})"
else
  fail "Only ${FREE_GB:-0} GB free disk — need >= ${MIN_DISK_FREE_GB} GB (the image cache alone needs ~15 GB)"
fi

# --- Required CLIs ---------------------------------------------------------
# tbx is only required on the substrate that uses it — dev-setup.sh does not
# install it (it needs a privileged one-time `sudo tbx system install`), so
# demanding it on the docker substrate would fail every Windows/WSL2 attendee.
TOOLS="talosctl kubectl helm cilium jq git curl"
if [ "$SUBSTRATE" = tbx ]; then TOOLS="$TOOLS tbx"; fi
# Deliberately unquoted: TOOLS is a space-separated word list, not one word.
# shellcheck disable=SC2086
for tool in $TOOLS; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool found ($(command -v "$tool"))"
  else
    if [ "$tool" = tbx ]; then
      fail "tbx not found in PATH — 'brew install randax/tap/tbx' (macOS) or the release tarball (Linux), then 'sudo tbx system install'; or use CLOUDBOX_SUBSTRATE=docker"
    else
      fail "$tool not found in PATH — run ./scripts/dev-setup.sh, then restart your shell (mise activation)"
    fi
  fi
done

# --- Repo pre-flight script ------------------------------------------------
if "$REPO_ROOT/scripts/install.sh" --check >/dev/null 2>&1; then
  ok "./scripts/install.sh --check passes"
else
  fail "./scripts/install.sh --check reports problems — run it directly to see them"
fi

# --- Image mirror ----------------------------------------------------------
if curl -fsS --max-time 5 http://localhost:5001/v2/ >/dev/null 2>&1; then
  ok "cloudbox-mirror registry answers on localhost:5001"
  IMAGES="$(curl -fsS --max-time 5 http://localhost:5001/v2/_catalog 2>/dev/null | jq -r '.repositories | length' 2>/dev/null || echo 0)"
  if [ "${IMAGES:-0}" -gt 0 ]; then
    ok "mirror holds ${IMAGES} repositories (pre-pull has run)"
  else
    fail "mirror is empty — run ./scripts/cloudbox-init.sh (needs good WiFi, resumable)"
  fi
else
  fail "no registry on localhost:5001 — run ./scripts/cloudbox-init.sh to start and fill the cloudbox-mirror"
fi

# --- Talos disk image (tbx only) -------------------------------------------
# The VMs boot from a raw disk image, which the container mirror knows nothing
# about — it lives in tbx's own cache, keyed by version directory. Assert the
# FILE, not the directory: an interrupted pull leaves the directory behind
# empty (same reasoning as scripts/install.sh).
if [ "$SUBSTRATE" = tbx ]; then
  if find "${HOME}/.talosbox/cache" -type f -path "*/${TALOS_VERSION}/*disk.raw" -size +0c 2>/dev/null | grep -q .; then
    ok "Talos ${TALOS_VERSION} disk image is cached for tbx"
  else
    fail "no complete Talos ${TALOS_VERSION} disk.raw in ~/.talosbox/cache — run ./scripts/cloudbox-init.sh (needs the Image Factory, so do it at home)"
  fi
fi

# --- Summary ---------------------------------------------------------------
echo
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED check(s) failed — you are not ready yet. Fix the FAIL lines above (pair up or use the devcontainer lifeboat if the hardware says no)."
  exit 1
fi
echo "✅ All pre-flight checks passed. You are ready for module 01."
