#!/usr/bin/env bash
# =============================================================================
# Shared helpers for CloudBox workshop scripts.
#
# Usage (from any script in scripts/):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib.sh"
#
# Provides: colored ok/fail/warn/info/step logging, die, have, need,
# confirm, detect_arch, is_wsl2, mirror_running, mirror_host_endpoint —
# and sources versions.env so every pin is available as a variable.
# =============================================================================

# Guard against direct execution — this file is meant to be sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib.sh is a library; source it from another script." >&2
  exit 1
fi

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LIB_DIR}/.." && pwd)"
export REPO_ROOT

# shellcheck source=versions.env
source "${LIB_DIR}/versions.env"

# --- Logging -----------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

ok()   { echo "${C_GREEN}✅ $*${C_RESET}"; }
fail() { echo "${C_RED}❌ $*${C_RESET}"; }
warn() { echo "${C_YELLOW}⚠️  $*${C_RESET}"; }
info() { echo "${C_BLUE}ℹ️  $*${C_RESET}"; }
step() { echo; echo "${C_BOLD}==> $*${C_RESET}"; }
die()  { fail "$@"; exit 1; }

# --- Small utilities -----------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# need <cmd> [hint] — die with a friendly message if a tool is missing.
need() {
  have "$1" || die "'$1' not found. ${2:-Run ./scripts/dev-setup.sh first.}"
}

# confirm "question" — interactive yes/no, defaults to no. Returns 0 on yes.
confirm() {
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]]
}

# detect_arch — prints amd64 or arm64, fails on anything else.
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) return 1 ;;
  esac
}

# is_wsl2 — true when running inside Windows Subsystem for Linux.
is_wsl2() {
  [[ -f /proc/version ]] && grep -qi microsoft /proc/version
}

docker_running() {
  have docker && docker info >/dev/null 2>&1
}

# mirror_running — true when the cloudbox-mirror registry container is up.
mirror_running() {
  docker_running && \
    [[ "$(docker inspect -f '{{.State.Running}}' "${MIRROR_NAME}" 2>/dev/null)" == "true" ]]
}

# mirror_host_endpoint — address where CLUSTER NODE CONTAINERS reach the mirror.
#   macOS / WSL2 (Docker Desktop, OrbStack): host.docker.internal resolves in
#   containers. Native Linux: the Talos docker network gateway IP is the host,
#   and the mirror publishes on 0.0.0.0:5001. Override with CLOUDBOX_MIRROR_HOST.
mirror_host_endpoint() {
  local host
  if [[ -n "${CLOUDBOX_MIRROR_HOST:-}" ]]; then
    host="${CLOUDBOX_MIRROR_HOST}"
  elif [[ "$(uname -s)" == "Darwin" ]] || is_wsl2; then
    host="host.docker.internal"
  else
    host="${TALOS_SUBNET_GATEWAY}"
  fi
  echo "http://${host}:${MIRROR_PORT}"
}

# strip_registry <image-ref> — drop the registry host from an image reference,
# leaving the repository path + tag/digest. This is the path a containerd
# registry mirror is queried with. Examples:
#   ghcr.io/siderolabs/talos:v1.13.6    -> siderolabs/talos:v1.13.6
#   docker.io/library/registry:3.1.1    -> library/registry:3.1.1
strip_registry() {
  local ref="$1" first="${1%%/*}"
  if [[ "${first}" == *.* || "${first}" == *:* || "${first}" == "localhost" ]]; then
    echo "${ref#*/}"
  else
    echo "${ref}"   # no registry host prefix (shouldn't happen in images.txt)
  fi
}

# git_as_gitea_admin <git args...> — run git authenticating as the Gitea admin
# via GIT_ASKPASS instead of credentials embedded in the URL, so they stay out
# of process arguments and error output. (Workshop-grade creds, but URLs with
# passwords also break when the password ever needs URL-encoding.)
git_as_gitea_admin() {
  local askpass rc=0
  askpass="$(mktemp)"
  printf '#!/bin/sh\ncase "$1" in\n  Username*) echo "%s" ;;\n  *) echo "%s" ;;\nesac\n' \
    "${GITEA_ADMIN_USER}" "${GITEA_ADMIN_PASSWORD}" > "${askpass}"
  chmod 700 "${askpass}"
  GIT_ASKPASS="${askpass}" GIT_TERMINAL_PROMPT=0 git "$@" || rc=$?
  rm -f "${askpass}"
  return "${rc}"
}
