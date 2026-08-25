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
# sources versions.env so every pin is available as a variable, and defines
# (but does not call) require_workshop_context from context-guard.sh.
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

# The workshop-context guard — DEFINED here, deliberately NOT called. Sourcing
# lib.sh must stay safe before a cluster exists: create-cluster.sh and
# kind-fallback.sh source this file and are what CREATE the workshop context, so
# a source-time call would make the workshop impossible to start. Every script
# that talks to an existing cluster calls require_workshop_context explicitly,
# after its own create/rebuild branch; check-consistency.sh check 8 enforces
# that and carries the justified allowlist of the pre-cluster exceptions.
# shellcheck source=context-guard.sh
source "${LIB_DIR}/context-guard.sh"

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
  have "$1" || die "'$1' not found. ${2:-Run ./scripts/dev-setup.sh first, or restart your shell so mise activation takes effect.}"
}

# talos_cluster_state_dir — where `talosctl cluster create` keeps a cluster's
# provisioner state (its --state flag, default $HOME/.talos/clusters).
#
# It outlives the node containers, and nothing in the Docker world removes it:
# deleting the Docker VM (Colima `colima delete`, Docker Desktop "Reset to
# factory defaults"), pruning containers by hand, or a create that died after
# PKI generation all leave it behind. The next `talosctl cluster create` then
# refuses before it does anything:
#
#   failed to initialize provisioner state: state directory ".../cloudbox"
#   already exists, is the cluster "cloudbox" already running?
#
# Exactly the same shape as the stale talosconfig context both scripts already
# self-heal, so both clear this too — otherwise destroy-cluster.sh reports
# "nothing to destroy" (there are no containers) and create-cluster.sh keeps
# failing, with no documented command in between that fixes it.
talos_cluster_state_dir() { echo "${HOME}/.talos/clusters/${CLUSTER_NAME}"; }

# wait_rollout <ns> <kind/name> [timeout-seconds] — a robust rollout wait for the
# bootstrap path. A single `kubectl rollout status --timeout` fails HARD the
# moment a cold cluster's first image pull or a scheduling delay overruns the
# clock (the recurring "timed out waiting for the condition" flake). This wraps
# it with a generous default timeout and ONE retry — a slow first pull almost
# always succeeds on the second attempt — and, only on a genuine final failure,
# dumps the namespace's pod status + recent events so it's debuggable instead of
# a bare timeout. Idempotent and safe for attendees, not just CI.
wait_rollout() {
  local ns="$1" obj="$2" timeout="${3:-300}" attempt
  for attempt in 1 2; do
    if kubectl -n "$ns" rollout status "$obj" --timeout="${timeout}s"; then
      return 0
    fi
    warn "rollout ${ns}/${obj} not ready after ${timeout}s (attempt ${attempt}/2) — retrying"
  done
  fail "rollout ${ns}/${obj} never became ready — recent state:"
  kubectl -n "$ns" get pods -o wide 2>/dev/null || true
  kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
  return 1
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

# docker_server_arch — the Docker DAEMON's architecture (amd64/arm64), which is
# what the cluster node containers run. Can differ from uname -m: an x86_64
# Rosetta shell on Apple Silicon, or a context pointing at a remote daemon.
# Anything arch-sensitive about images (the mirror!) must use this, not
# detect_arch. Fails when the daemon is unreachable or reports an unknown arch.
docker_server_arch() {
  local a
  a="$(docker version -f '{{.Server.Arch}}' 2>/dev/null)" || return 1
  case "${a}" in
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

# --- Substrate ------------------------------------------------------------------
# Which machine substrate this cluster runs on: real Talos VMs via talos-box
# (`tbx`) or Talos-in-Docker containers. Both satisfy the same contract, which
# lab/01-cluster/verify.sh asserts; the difference is where the API server and
# the ingress endpoint live. See docs/superpowers/plans/2026-08-24-talos-box-substrate.md.
CLOUDBOX_SUBSTRATE_FILE="${HOME}/.cloudbox/substrate"

# substrate_doctor_reason — the first FAIL line `tbx doctor` printed, or a
# one-liner saying why tbx was not even asked. Read-only; never runs a cluster
# operation. Used by install.sh --check to explain a fallback instead of just
# announcing one.
substrate_doctor_reason() {
  if ! have tbx; then
    echo "tbx is not installed (brew install randax/tap/tbx, or the release tarball on Linux)"
    return 0
  fi
  local out
  out="$(tbx doctor 2>&1 || true)"
  local line
  line="$(printf '%s\n' "${out}" | grep -m1 '^FAIL ' || true)"
  echo "${line:-tbx doctor did not report a FAIL line}"
}

# substrate_detect — the substrate this MACHINE can run, with no persisted
# answer and no override. tbx needs its daemon+helper installed and healthy, so
# `tbx doctor` (which exits non-zero on any FAIL — cmd/tbx/doctor.go:345-347) is
# the gate, not the mere presence of the binary.
substrate_detect() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  if have tbx; then
    case "${os}:${arch}" in
      Darwin:arm64|Linux:x86_64|Linux:aarch64|Linux:arm64|Linux:amd64)
        if tbx doctor >/dev/null 2>&1; then echo "tbx"; return 0; fi ;;
    esac
  fi
  echo "docker"
}

# substrate_persist <tbx|docker> — record the substrate the cluster was CREATED
# on. Everything downstream reads this rather than re-detecting: a laptop that
# loses `tbx doctor` mid-workshop must not make destroy-cluster.sh look for
# docker containers that never existed.
substrate_persist() {
  local value="$1"
  case "${value}" in tbx|docker) ;; *) die "substrate_persist: unknown substrate '${value}'" ;; esac
  mkdir -p "$(dirname "${CLOUDBOX_SUBSTRATE_FILE}")"
  printf '%s\n' "${value}" > "${CLOUDBOX_SUBSTRATE_FILE}.tmp"
  mv "${CLOUDBOX_SUBSTRATE_FILE}.tmp" "${CLOUDBOX_SUBSTRATE_FILE}"
}

# substrate_current — the persisted answer, or empty when no cluster has been
# created on this machine yet (or the persisted file holds anything other than
# tbx/docker — corruption is treated as "no answer", not as that literal
# string). Never detects; never writes.
substrate_current() {
  [[ -r "${CLOUDBOX_SUBSTRATE_FILE}" ]] || return 0
  local value
  value="$(tr -d '[:space:]' < "${CLOUDBOX_SUBSTRATE_FILE}")"
  case "${value}" in
    tbx|docker) echo "${value}" ;;
    *)
      warn "${CLOUDBOX_SUBSTRATE_FILE} contains '${value}', not 'tbx' or 'docker' — ignoring it" >&2
      return 1
      ;;
  esac
}

# substrate_resolve — the substrate to USE right now, in precedence order:
#   1. an explicit CLOUDBOX_SUBSTRATE in the environment (the documented escape
#      hatch, e.g. CLOUDBOX_SUBSTRATE=tbx on a machine that failed detection)
#   2. the persisted answer from a previous create
#   3. detection, floored by CLOUDBOX_SUBSTRATE_DEFAULT: when the default is
#      "docker" (the go-live gate having flipped it), detection never upgrades.
# Callers: assign the result to a variable first (`local s; s="$(substrate_resolve)"`)
# and check it there — never compare inside `[[ "$(substrate_resolve)" == ... ]]`,
# since a `die` inside that command substitution only kills the subshell and the
# comparison would silently see an empty string instead of aborting.
substrate_resolve() {
  if [[ -n "${CLOUDBOX_SUBSTRATE:-}" ]]; then
    case "${CLOUDBOX_SUBSTRATE}" in
      tbx|docker) echo "${CLOUDBOX_SUBSTRATE}"; return 0 ;;
      *) die "CLOUDBOX_SUBSTRATE='${CLOUDBOX_SUBSTRATE}' is not 'tbx' or 'docker'" ;;
    esac
  fi
  local persisted
  persisted="$(substrate_current || true)"
  if [[ -n "${persisted}" ]]; then echo "${persisted}"; return 0; fi
  if [[ "${CLOUDBOX_SUBSTRATE_DEFAULT}" == "docker" ]]; then echo "docker"; return 0; fi
  substrate_detect
}

# tbx_version_check <reporter> — assert the tbx on PATH is the PINNED one,
# reporting a mismatch through <reporter> (`die` on the create path,
# check_fail in install.sh --check). Lives in lib.sh, not in substrate/tbx.sh,
# so --check can make the assertion without sourcing a create backend.
#
# Nothing asserted this before: check 10 in check-consistency.sh keeps
# versions.env and mise.toml agreeing with EACH OTHER, and says in its own
# comment that asserting the actual binary is the preflight's job — because tbx
# has no mise backend yet (upstream #95/#96/#101), so mise installs and enforces
# nothing. An attendee who ran `brew upgrade` gets whatever the tap has today,
# and the cluster-yaml schema and the `tbx manifests` sections we render are
# exactly the parts that move between versions.
#
# `tbx version` prints "tbx v0.1.1 (<commit>, <date>)"; take field 2 and accept
# a bare "0.1.1" too. An unreadable answer is a mismatch, not a pass.
# CLOUDBOX_ALLOW_TBX_DRIFT=1 is the documented escape hatch for whoever is
# deliberately testing a newer tbx before the pin moves.
tbx_version_check() {
  local report="$1" found
  # Field 2 of "tbx v0.1.1 (<commit>, <date>)". The field-1 fallback covers a
  # future `tbx version` that prints the bare version, so a cosmetic upstream
  # change reads as drift-to-investigate rather than "unreadable" on every run.
  found="$(tbx version 2>/dev/null \
    | awk 'NR == 1 { if ($2 ~ /^v?[0-9]/) print $2; else if ($1 ~ /^v?[0-9]/) print $1 }' || true)"
  [[ -n "${found}" && "${found}" != v* ]] && found="v${found}"
  if [[ "${found}" == "${TBX_VERSION}" ]]; then
    ok "tbx ${TBX_VERSION} (the pinned version)"
    return 0
  fi
  if [[ "${CLOUDBOX_ALLOW_TBX_DRIFT:-}" == "1" ]]; then
    warn "tbx is ${found:-unreadable}, pinned is ${TBX_VERSION} — allowed by CLOUDBOX_ALLOW_TBX_DRIFT=1"
    return 0
  fi
  "${report}" "tbx version drift: this machine has ${found:-an unreadable version}, the workshop is pinned to ${TBX_VERSION} (scripts/versions.env). Install the pin (brew install randax/tap/tbx, or the matching release tarball), set CLOUDBOX_ALLOW_TBX_DRIFT=1 to proceed unpinned, or use the docker substrate: CLOUDBOX_SUBSTRATE=docker"
}

# cloudbox_host_gateway — the HOST as workloads INSIDE the cluster see it.
# ONE definition, used by both backends and by bootstrap-gitops.sh (kagent's
# Ollama endpoint), catch-up.sh and the labs — each of which runs in its own
# shell long after create-cluster.sh exported CLOUDBOX_HOST_GATEWAY, so it is
# re-derived rather than inherited. Honours an already-exported value first so
# a backend that has just computed it does not pay for a second lookup.
#   tbx     172.30.<n>.1  — the cluster gateway (upstream docs/SPEC.md:186-192)
#   docker  host.docker.internal (macOS/WSL2) or TALOS_SUBNET_GATEWAY (Linux),
#           the same rule mirror_host_endpoint() uses, without scheme or port
# Callers must ASSIGN the result (`gw="$(cloudbox_host_gateway)"`), never compare
# it inline: this function's failure is a non-zero status, which an assignment
# propagates (and `set -e` acts on) and a `[[ "$(...)" == ... ]]` swallows.
cloudbox_host_gateway() {
  if [[ -n "${CLOUDBOX_HOST_GATEWAY:-}" ]]; then echo "${CLOUDBOX_HOST_GATEWAY}"; return 0; fi
  local substrate
  substrate="$(substrate_resolve)"
  if [[ "${substrate}" == "tbx" ]]; then
    # Every failure message in this function goes to STDERR, and the function
    # returns instead of dying: die() prints through fail() on stdout, which in
    # `gw="$(cloudbox_host_gateway)"` would hand the caller the ❌ line AS THE
    # GATEWAY ADDRESS. On stderr the attendee still sees it, the assignment gets
    # an empty string, and the non-zero return aborts under set -e.
    need jq >&2
    local subnet
    # `tbx status <cluster> -o json` prints an ARRAY of ClusterStatus even for a
    # single named cluster (cmd/tbx/main.go:661-670), so `.subnet` alone makes
    # jq error out and this die fire on a perfectly healthy cluster. The array
    # is normalised here; the object branch keeps a later tbx that unwraps it
    # working. Same normaliser as tbx_cluster_json() in substrate/tbx.sh.
    subnet="$(tbx status "${CLUSTER_NAME}" -o json 2>/dev/null \
      | jq -r --arg c "${CLUSTER_NAME}" \
          'if type == "array" then ((map(select(.name == $c)) | first) // {}) else . end | .subnet // empty' \
          2>/dev/null || true)"
    if [[ -z "${subnet}" ]]; then
      fail "cannot read the tbx cluster subnet — is '${CLUSTER_NAME}' up? (tbx status ${CLUSTER_NAME})" >&2
      return 1
    fi
    echo "${subnet%.*}.1"
  elif [[ -n "${CLOUDBOX_MIRROR_HOST:-}" ]]; then
    echo "${CLOUDBOX_MIRROR_HOST}"
  elif [[ "$(uname -s)" == "Darwin" ]] || is_wsl2; then
    echo "host.docker.internal"
  else
    echo "${TALOS_SUBNET_GATEWAY}"
  fi
}

# --- talosconfig contexts ---------------------------------------------------
# A leftover '${CLUSTER_NAME}' context is the same bug on every path: talosctl
# refuses to reuse the name, so the NEW cluster's context becomes
# '${CLUSTER_NAME}-1' and every `talosctl --context ${CLUSTER_NAME}` afterwards
# dials the cluster that no longer exists. destroy-cluster.sh clears it, both
# create backends re-check it (a hand-run destroy, an older destroy, or a create
# that died halfway), so the helpers live HERE rather than three times over.
#
# Matched with pipe-free bash, NOT `talos_contexts | grep`. Under
# `set -euo pipefail` the two greps this replaces were one live bug and one
# latent one:
#
#   `other="$(talos_contexts | grep -vx "${CLUSTER_NAME}" | head -1)"` — when
#   '${CLUSTER_NAME}' is the ONLY context, grep -vx matches nothing and exits 1.
#   A bare assignment inherits its command substitution's status, so `set -e`
#   killed the script HERE, before the single-context branch below — the branch
#   that exists for precisely that case — could run. On the destroy path that
#   broke `catch-up.sh --rebuild` for everyone whose machine had nothing else in
#   ~/.talos/config, which is the normal attendee state; on the create path it
#   turned a stale context into a create that dies with no diagnosis at all.
#   Caught by the CI recovery-path job, which is a fresh runner and therefore
#   always the one-context case.
#
#   `talos_contexts | grep -qx "${CLUSTER_NAME}"` — LATENT, not observed: grep
#   -q exits at the first match, and if awk is still writing it takes EPIPE,
#   which pipefail turns into a non-zero pipeline — i.e. a context that IS
#   present reads as absent and the removal is skipped, silently. Measured, it
#   needs ~5000 contexts before awk's output stops fitting in one pipe buffer,
#   so nobody was ever going to hit it. Rewritten anyway: the fix for the live
#   bug above is a pipe-free matcher, and leaving one grep behind would keep
#   the class alive for the next person who copies the line.
talos_contexts() { # -> one context name per line, '*' marker stripped
  talosctl config contexts 2>/dev/null | awk 'NR > 1 { print ($1 == "*") ? $2 : $1 }'
}

has_talos_context() { # $1 = context name
  local c
  while IFS= read -r c; do
    [[ "${c}" == "$1" ]] && return 0
  done <<<"$(talos_contexts)"
  return 1
}

first_other_talos_context() { # $1 = context to exclude; prints nothing if none
  local c
  while IFS= read -r c; do
    if [[ -n "${c}" && "${c}" != "$1" ]]; then printf '%s\n' "${c}"; return 0; fi
  done <<<"$(talos_contexts)"
  return 0   # no other context is a normal outcome, not a failure — see above
}

# remove_talos_context <name> — best effort, and idempotent. `talosctl config
# remove` SKIPS the context that is currently SELECTED and still exits 0 while
# saying so ("skipping removal of current context ..., please change it to
# another before removing"), so the bare call removed nothing, undetectably.
# Switch away first. When there is nothing to switch to, the whole talosconfig
# describes only the cluster being removed — delete the file; talosctl recreates
# it on the next cluster create. Callers verify with has_talos_context.
remove_talos_context() {
  local name="$1" other
  has_talos_context "${name}" || return 0
  other="$(first_other_talos_context "${name}")"
  if [[ -n "${other}" ]]; then
    talosctl config context "${other}" >/dev/null 2>&1 || true
    talosctl config remove "${name}" --noconfirm >/dev/null 2>&1 || true
  else
    rm -f "${TALOSCONFIG:-${HOME}/.talos/config}"
  fi
}

# --- The /etc/hosts block (docker substrate only) -------------------------------
# On tbx, talos-box's own resolver answers *.${CLOUDBOX_DOMAIN} with the
# cluster's ingress VIP and there is nothing to write. On docker there is no
# resolver and no wildcard, so the hostnames are listed one by one, in a MARKED
# block we own end-to-end: idempotent to write, exactly removable, and never
# touching a line we did not put there.
CLOUDBOX_HOSTS_BEGIN="# cloudbox-begin"
CLOUDBOX_HOSTS_END="# cloudbox-end"
CLOUDBOX_HOSTS_FILE="${CLOUDBOX_HOSTS_FILE:-/etc/hosts}"

# cloudbox_hostnames — every name the workshop serves, one per line.
# Derived from the *_HOST_URL pins in versions.env rather than re-typed here:
# there is exactly one place a hostname is written down, and renaming a service
# there moves the /etc/hosts line with it. The nine service names, plus the
# three Knative names the labs create (lab/06-serverless -> hello-demo,
# gitops/components/picture-pipeline -> uploader-pipeline, resizer-pipeline).
#
# Knative hosts are <name>-<namespace>.${KNATIVE_DOMAIN} — the single-label
# `domain-template` curation in knative-serving/serving-core.yaml. On tbx that
# whole shape is covered by talos-box's wildcard resolver and this list is not
# consulted at all; /etc/hosts has no wildcards, so on docker the three names
# the labs create are enumerated and anything an attendee creates themselves
# needs a manual line, a `curl -H Host:`, or NodePort 31080. lab/06 says so,
# and its verifier reads the Knative Service's published .status.url rather
# than assuming the shape.
cloudbox_hostnames() {
  local url host
  for url in "${GITEA_HOST_URL}" "${ARGOCD_HOST_URL}" "${PORTAL_HOST_URL}" \
             "${GRAFANA_HOST_URL}" "${RUSTFS_S3_HOST_URL}" "${RUSTFS_CONSOLE_HOST_URL}" \
             "${BACKSTAGE_HOST_URL}" "${ZOT_HOST_URL}" "${NATS_HOST_URL}"; do
    host="${url#*://}"        # drop the scheme
    echo "${host%%[:/]*}"     # drop any :port or /path
  done
  local n
  for n in hello-demo uploader-pipeline resizer-pipeline; do
    echo "${n}.${KNATIVE_DOMAIN}"
  done
}

cloudbox_hosts_block() {
  echo "${CLOUDBOX_HOSTS_BEGIN}"
  echo "# CloudBox workshop — the docker substrate has no resolver, so every"
  echo "# hostname is listed here. Written by ./scripts/create-cluster.sh,"
  echo "# removed by ./scripts/destroy-cluster.sh --purge-mirror. Safe to delete"
  echo "# by hand: nothing outside these two markers is ever touched."
  local n
  while IFS= read -r n; do echo "127.0.0.1 ${n}"; done < <(cloudbox_hostnames)
  echo "${CLOUDBOX_HOSTS_END}"
}

# hosts_block_present — 0 when the block exists AND lists every current name.
# A block that is merely present is not enough: adding a hostname to
# cloudbox_hostnames must make this fail so the block gets rewritten.
hosts_block_present() {
  [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] || return 1
  grep -qxF "${CLOUDBOX_HOSTS_BEGIN}" "${CLOUDBOX_HOSTS_FILE}" || return 1
  local n
  while IFS= read -r n; do
    grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+${n//./\\.}([[:space:]]|$)" \
      "${CLOUDBOX_HOSTS_FILE}" || return 1
  done < <(cloudbox_hostnames)
  return 0
}

# hosts_missing_names — the names NOT currently resolvable from the file, so a
# FAIL message can name them instead of saying "the block is wrong".
hosts_missing_names() {
  local n
  while IFS= read -r n; do
    grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+${n//./\\.}([[:space:]]|$)" \
      "${CLOUDBOX_HOSTS_FILE}" 2>/dev/null || echo "${n}"
  done < <(cloudbox_hostnames)
}

# write_hosts_block — replace the marked block (or append it). Needs sudo, once.
# Written via a temp file and `sudo tee`, never an in-place sudo sed: a
# half-written /etc/hosts breaks name resolution for the whole machine.
write_hosts_block() {
  hosts_block_present && { ok "${CLOUDBOX_HOSTS_FILE} block already correct"; return 0; }
  local tmp; tmp="$(mktemp)"
  # Set AFTER mktemp so an early `return 0` above never runs it with tmp unset.
  # shellcheck disable=SC2064  # expand tmp NOW: at RETURN time the local is gone
  trap "rm -f '${tmp}'" RETURN
  if [[ -r "${CLOUDBOX_HOSTS_FILE}" ]]; then
    awk -v b="${CLOUDBOX_HOSTS_BEGIN}" -v e="${CLOUDBOX_HOSTS_END}" \
      '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' \
      "${CLOUDBOX_HOSTS_FILE}" > "${tmp}"
  fi
  cloudbox_hosts_block >> "${tmp}"
  warn "Adding the CloudBox hostnames to ${CLOUDBOX_HOSTS_FILE} — this needs sudo, once."
  info "See exactly what goes in with: ./scripts/install.sh --print-hosts"
  # shellcheck disable=SC2024  # deliberate: the INPUT redirect is our own
  # mktemp file, readable without sudo; only the WRITE needs root, and tee does
  # that. `sudo cat | tee` would be the wrong way round here.
  #
  # The failure is handled rather than left to `set -e`, because THIS is the
  # command an attendee can refuse: a declined (or absent) sudo password makes
  # tee exit non-zero, and a bare `set -e` abort here would leave a full copy of
  # /etc/hosts in $TMPDIR forever. The RETURN trap above covers the ordinary
  # paths; only an exit can escape it, so the exiting path cleans up itself.
  if ! sudo tee "${CLOUDBOX_HOSTS_FILE}" < "${tmp}" >/dev/null; then
    rm -f "${tmp}"
    die "Could not write ${CLOUDBOX_HOSTS_FILE} (sudo declined or unavailable). Add the lines by hand: ./scripts/install.sh --print-hosts"
  fi
  rm -f "${tmp}"
  hosts_block_present || die "Wrote ${CLOUDBOX_HOSTS_FILE} but the names still do not resolve — check it by hand"
  ok "${CLOUDBOX_HOSTS_FILE} updated ($(cloudbox_hostnames | wc -l | tr -d ' ') names)"
}

remove_hosts_block() {
  [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] || return 0
  grep -qxF "${CLOUDBOX_HOSTS_BEGIN}" "${CLOUDBOX_HOSTS_FILE}" || return 0
  local tmp; tmp="$(mktemp)"
  # shellcheck disable=SC2064  # see write_hosts_block
  trap "rm -f '${tmp}'" RETURN
  awk -v b="${CLOUDBOX_HOSTS_BEGIN}" -v e="${CLOUDBOX_HOSTS_END}" \
    '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' \
    "${CLOUDBOX_HOSTS_FILE}" > "${tmp}"
  warn "Removing the CloudBox block from ${CLOUDBOX_HOSTS_FILE} — this needs sudo."
  # shellcheck disable=SC2024  # see write_hosts_block: the redirect reads our
  # own temp file; sudo is only needed for the write tee performs.
  if ! sudo tee "${CLOUDBOX_HOSTS_FILE}" < "${tmp}" >/dev/null; then
    rm -f "${tmp}"
    die "Could not rewrite ${CLOUDBOX_HOSTS_FILE} (sudo declined or unavailable). Delete the lines between ${CLOUDBOX_HOSTS_BEGIN} and ${CLOUDBOX_HOSTS_END} by hand."
  fi
  rm -f "${tmp}"
  ok "${CLOUDBOX_HOSTS_FILE} block removed"
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
  # shellcheck disable=SC2016  # $1 is for the generated script, not this shell
  printf '#!/bin/sh\ncase "$1" in\n  Username*) echo "%s" ;;\n  *) echo "%s" ;;\nesac\n' \
    "${GITEA_ADMIN_USER}" "${GITEA_ADMIN_PASSWORD}" > "${askpass}"
  chmod 700 "${askpass}"
  GIT_ASKPASS="${askpass}" GIT_TERMINAL_PROMPT=0 git "$@" || rc=$?
  rm -f "${askpass}"
  return "${rc}"
}
