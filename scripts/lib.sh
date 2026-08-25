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

# node_arch — the CPU architecture the CLUSTER NODES will run, which is a
# different question per substrate and is what every image decision (the
# mirror!) depends on:
#   docker — the nodes ARE containers on this host's Docker engine, so the
#            daemon's arch is theirs; on an amd64 Colima VM on an arm64 Mac
#            that is amd64, and uname -m would be wrong.
#   tbx    — the nodes are VMs virtualised natively (vz/hvf on macOS, KVM on
#            Linux); nothing is emulated, so they are the HOST's arch, and the
#            Docker daemon — which here only ever runs the mirror — may not be
#            the same one at all.
# Callers that already know the substrate pass it in $1; otherwise this
# resolves it (which can run `tbx doctor`).
node_arch() { # [substrate]
  local s="${1:-}"
  [[ -n "${s}" ]] || substrate_resolve_into s || return 1
  if [[ "${s}" == "tbx" ]]; then detect_arch; return; fi
  docker_server_arch
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
  tbx_doctor_run || true
  local line
  line="$(printf '%s\n' "${TBX_DOCTOR_OUT}" | grep -m1 '^FAIL ' || true)"
  echo "${line:-tbx doctor did not report a FAIL line}"
}

# tbx_doctor_run — `tbx doctor`, ONCE per process. Output in TBX_DOCTOR_OUT,
# verdict in the return status. `tbx doctor` probes the helper, DNS, the routes
# and the mirror; it is the slowest read-only thing this repo runs, and it was
# being run three times over in a single `install.sh --check` — the detection
# inside substrate_resolve, the visible run in the tbx section, and again by
# substrate_doctor_reason to quote one FAIL line from output it had just thrown
# away. Callers that want to SHOW it print TBX_DOCTOR_OUT.
#
# Memoised for the life of the process, which is the right scope: every caller
# is within seconds of the others, and nothing here can change the verdict.
TBX_DOCTOR_OUT=""
TBX_DOCTOR_RC=""
tbx_doctor_run() {
  if [[ -z "${TBX_DOCTOR_RC}" ]]; then
    if TBX_DOCTOR_OUT="$(tbx doctor 2>&1)"; then TBX_DOCTOR_RC=0; else TBX_DOCTOR_RC=1; fi
  fi
  [[ "${TBX_DOCTOR_RC}" == "0" ]]
}

# substrate_detect — the substrate this MACHINE can run, with no persisted
# answer and no override. tbx needs its daemon+helper installed and healthy, so
# `tbx doctor` (which exits non-zero on any FAIL — cmd/tbx/doctor.go:345-347) is
# the gate, not the mere presence of the binary.
substrate_detect_into() { # <varname>
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  printf -v "$1" '%s' "docker"
  if have tbx; then
    case "${os}:${arch}" in
      Darwin:arm64|Linux:x86_64|Linux:aarch64|Linux:arm64|Linux:amd64)
        if tbx_doctor_run; then printf -v "$1" '%s' "tbx"; fi ;;
    esac
  fi
  return 0
}
substrate_detect() { local __s; substrate_detect_into __s; echo "${__s}"; }

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

# --- The persisted API endpoint --------------------------------------------
# The WRITERS for ${CLOUDBOX_API_ENDPOINT_FILE}; the file itself and the reader
# live in context-guard.sh, because lab/common.sh sources that guard WITHOUT
# lib.sh and the guard is the one thing that must be able to read this.
api_endpoint_persist() { # <https://host:port>
  local value="$1"
  [[ -n "${value}" ]] || return 1
  mkdir -p "$(dirname "${CLOUDBOX_API_ENDPOINT_FILE}")"
  printf '%s\n' "${value}" > "${CLOUDBOX_API_ENDPOINT_FILE}.tmp"
  mv "${CLOUDBOX_API_ENDPOINT_FILE}.tmp" "${CLOUDBOX_API_ENDPOINT_FILE}"
}

api_endpoint_forget() { rm -f "${CLOUDBOX_API_ENDPOINT_FILE}"; }

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
# since a failure inside that command substitution only ends the subshell and
# the comparison would silently see an empty string instead of aborting.
#
# The rejection is `fail … >&2; return 1`, not `die`: die() prints through
# fail() on STDOUT (kept that way on purpose — every other caller in the tree
# reads those messages on stdout), and inside `s="$(substrate_resolve)"` a
# stdout message becomes the *value* of s, not a diagnostic anyone sees. On
# stderr the attendee reads the real reason, the assignment gets an empty
# string, and the non-zero status aborts the caller under `set -e`.
substrate_resolve_into() { # <varname> — substrate_resolve without the subshell
  local __var="$1" __persisted
  if [[ -n "${CLOUDBOX_SUBSTRATE:-}" ]]; then
    case "${CLOUDBOX_SUBSTRATE}" in
      tbx|docker) printf -v "${__var}" '%s' "${CLOUDBOX_SUBSTRATE}"; return 0 ;;
      *) fail "CLOUDBOX_SUBSTRATE='${CLOUDBOX_SUBSTRATE}' is not 'tbx' or 'docker'" >&2; return 1 ;;
    esac
  fi
  __persisted="$(substrate_current || true)"
  if [[ -n "${__persisted}" ]]; then printf -v "${__var}" '%s' "${__persisted}"; return 0; fi
  if [[ "${CLOUDBOX_SUBSTRATE_DEFAULT}" == "docker" ]]; then printf -v "${__var}" '%s' "docker"; return 0; fi
  substrate_detect_into "${__var}"
}

# The `$( )` form, for the places that read the answer inline. Prefer
# substrate_resolve_into in a script that will ask anything else about tbx: a
# command substitution is a SUBSHELL, so the `tbx doctor` memo that detection
# fills in (TBX_DOCTOR_RC) dies with it, and the next caller —
# substrate_preflight, substrate_doctor_reason, install.sh's visible run — pays
# for a second full probe of the helper, DNS, routes and mirror. Seconds, twice,
# on a path the attendee is already waiting on.
substrate_resolve() {
  local __s
  substrate_resolve_into __s || return 1
  echo "${__s}"
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

# tbx_cluster_absent <name> — is there a tbx cluster of this name?
#   0  proven ABSENT   — tbxd answered, and the answer was "no such cluster"
#   1  present         — `tbx status` succeeded
#   2  cannot inspect  — anything else; the reason is left in
#                        ${TBX_CLUSTER_ABSENT_REASON} for the caller to print
#
# The three-way answer is the whole point. `tbx status <cluster>` exits non-zero
# for two completely different reasons, and folding them into one boolean is how
# a destroy erases state it could not see:
#   * the cluster does not exist — `cluster.Load` cannot read its state file
#     (upstream internal/cluster/store.go:63-70, the ONLY site whose wrapper
#     says "read cluster state"), reached from the daemon's status op
#     (internal/daemon/operations.go:1445-1449). The message is
#     "read cluster state: open <dir>/<state file>: no such file or directory".
#   * tbxd is not reachable — the CLI dials a unix socket
#     (cmd/tbx/client.go:268, wrapped in dialError), and a MISSING SOCKET reads
#     "dial unix ~/.talosbox/tbxd.sock: connect: no such file or directory".
#     Upstream's own test fixture is that exact string
#     (cmd/tbx/doctor_platform_darwin_test.go:22).
# BOTH contain "no such file or directory". Accepting that substring on its own
# classifies a daemon that is merely DOWN as a cluster that does not EXIST — and
# the caller then deletes the only record that the running VMs are tbx's. So
# absence has to be proven by both halves of the narrow upstream wording, and
# everything else is "cannot inspect", which is never a licence to remove
# anything.
TBX_CLUSTER_ABSENT_REASON=""
tbx_cluster_absent() {
  local name="$1" out rc=0
  TBX_CLUSTER_ABSENT_REASON=""
  out="$(tbx status "${name}" 2>&1)" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    return 1
  fi
  if [[ "${out}" == *"read cluster state"* && "${out}" == *"no such file or directory"* ]]; then
    return 0
  fi
  # shellcheck disable=SC2034  # read by the preflights/destroy in substrate/*.sh
  TBX_CLUSTER_ABSENT_REASON="${out}"
  return 2
}

# tbx_host_memory_mib — the host's physical RAM in MiB, or nothing when this
# platform has no probe we trust. Deliberately the SAME sources tbxd reads, so
# our arithmetic and its overcommit gate cannot disagree about the host:
#   macOS  sysctl hw.memsize (bytes)   — internal/balloon/hostmem_darwin.go:17-23
#   Linux  /proc/meminfo MemTotal (kB) — tbxd has no Linux probe at all
#          (internal/balloon/hostmem_stub.go), so nothing to disagree with.
# Prints nothing rather than dying: it runs inside $( ), and the caller treats
# an unreadable host as "keep the pinned ceiling".
# Lives in lib.sh, not in substrate/tbx.sh, for the same reason
# tbx_version_check does: `install.sh --check` reports the host's RAM against
# the published floor on the tbx substrate, and a preflight must not have to
# source a create backend to ask a read-only question.
tbx_host_memory_mib() {
  local raw
  case "$(uname -s)" in
    Darwin)
      raw="$(sysctl -n hw.memsize 2>/dev/null || true)"
      [[ "${raw}" =~ ^[0-9]+$ ]] && echo $((raw / 1024 / 1024))
      ;;
    Linux)
      raw="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
      [[ "${raw}" =~ ^[0-9]+$ ]] && echo $((raw / 1024))
      ;;
  esac
  return 0
}

# host_cpu_count — the host's online core count, or nothing when no probe on
# this platform answers. The same expression substrate/tbx.sh already uses to
# size the worker VM (`getconf _NPROCESSORS_ONLN`), with the two usual fallbacks,
# so preflight and the renderer cannot disagree about how many cores this
# machine has.
#
# It exists because the published MIN_CPUS=4 was only ever enforced through
# `docker info -f '{{.NCPU}}'` — i.e. on the docker substrate. On tbx the nodes
# are VMs sized from the host, Docker's slice is irrelevant, and the whole
# CPU gate was skipped: a 2-core laptop passed preflight against a README that
# promises 4.
# Prints nothing rather than dying: it runs inside $( ), and an unreadable host
# is reported by the caller as "could not read", not as a failure.
host_cpu_count() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  [[ "${n}" =~ ^[0-9]+$ ]] || n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  [[ "${n}" =~ ^[0-9]+$ ]] || n="$(nproc 2>/dev/null || true)"
  [[ "${n}" =~ ^[0-9]+$ ]] && echo "${n}"
  return 0
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

# talos_config_target — the talosconfig FILE every context operation in this
# repo acts on: the caller's TALOSCONFIG if they have one, else talosctl's
# default. One expression, in one place, because create and destroy must not be
# able to disagree about it — the tbx backend used to `unset TALOSCONFIG` before
# merging, so on a laptop with a custom TALOSCONFIG the workshop's context went
# into a file that attendee's talosctl never reads, and the destroy then looked
# for it in the file it was not in.
talos_config_target() { echo "${TALOSCONFIG:-${HOME}/.talos/config}"; }

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
    rm -f "$(talos_config_target)"
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

# Extra short names an attendee asked for with `./scripts/install.sh
# --add-hosts <name>…` — one per line, no domain, e.g. `my-app-demo`. See
# cloudbox_extra_hostnames() below for why this file has to exist.
CLOUDBOX_EXTRA_HOSTS_FILE="${HOME}/.cloudbox/extra-hosts"

# cloudbox_extra_hostnames — the attendee's own Knative names, fully qualified.
#
# On tbx talos-box's resolver answers the whole `*.${KNATIVE_DOMAIN}` wildcard
# and none of this is consulted. /etc/hosts has NO wildcards, so on docker only
# the names we enumerate resolve — and the three the labs create are the only
# ones we can know in advance. Everything the Console composes (module 08's
# Application XR, into whichever project the attendee picked) and everything an
# attendee writes by hand is unknowable at create time. Recording them here is
# what makes `install.sh --add-hosts my-app-demo` re-derivable: the block is
# rewritten from cloudbox_hostnames(), so a name that is not persisted is a name
# the next rewrite silently drops.
#
# Anything that is not a bare DNS label is skipped WITH a warning rather than
# written into /etc/hosts: this file is edited by hand as often as not.
cloudbox_extra_hostnames() {
  [[ -r "${CLOUDBOX_EXTRA_HOSTS_FILE}" ]] || return 0
  local n
  # `|| [[ -n "${n}" ]]`: `read` returns non-zero on a final line with no
  # trailing newline, having already assigned it. A hand-edited file whose last
  # line is the name that matters ("echo my-app-demo >> …" without a newline,
  # an editor configured not to add one) would otherwise silently lose exactly
  # that name — and a name that is not in the block is a URL that does not
  # resolve on a cluster that is fine.
  while IFS= read -r n || [[ -n "${n}" ]]; do
    n="${n%%#*}"                       # allow trailing comments
    # Trim leading/trailing whitespace ONLY. Deleting every space (the previous
    # `${n//[[:space:]]/}`) turned "my app" into the perfectly valid label
    # "myapp" and wrote a name the attendee never asked for; inner whitespace
    # must reach the validator below and be REFUSED, not repaired.
    n="${n#"${n%%[![:space:]]*}"}"
    n="${n%"${n##*[![:space:]]}"}"
    [[ -z "${n}" ]] && continue
    if ! cloudbox_valid_label "${n}"; then
      warn "${CLOUDBOX_EXTRA_HOSTS_FILE}: ignoring '${n}' — not a DNS label (RFC 1123: a-z, 0-9 and '-', starting and ending alphanumeric, <= 63 chars)" >&2
      continue
    fi
    echo "${n}.${KNATIVE_DOMAIN}"
  done < "${CLOUDBOX_EXTRA_HOSTS_FILE}"
}

# cloudbox_valid_label <name> — RFC 1123's rule for ONE DNS label, which is what
# a Knative service name has to be. `[a-z0-9-]+` (the previous rule) accepts
# "-", "---" and a 200-character name: all of them go into /etc/hosts happily
# and none of them can ever resolve.
cloudbox_valid_label() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

# cloudbox_add_extra_host <name> — persist one short name, idempotently.
# Validates here rather than at the call site so every door into the file
# (today: install.sh --add-hosts) enforces the same rule.
cloudbox_add_extra_host() {
  local name="$1"
  cloudbox_valid_label "${name}" \
    || die "'${name}' is not a DNS label — RFC 1123 allows lowercase letters, digits and '-', starting and ending alphanumeric, at most 63 characters (pass the FIRST label only, e.g. my-app-demo for my-app-demo.${KNATIVE_DOMAIN})"
  mkdir -p "$(dirname "${CLOUDBOX_EXTRA_HOSTS_FILE}")"
  touch "${CLOUDBOX_EXTRA_HOSTS_FILE}"
  grep -qxF "${name}" "${CLOUDBOX_EXTRA_HOSTS_FILE}" && return 0
  printf '%s\n' "${name}" >> "${CLOUDBOX_EXTRA_HOSTS_FILE}"
}

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
# needs `./scripts/install.sh --add-hosts <name>` (which persists it in
# ${CLOUDBOX_EXTRA_HOSTS_FILE} and rewrites the block), a `curl -H Host:`, or
# NodePort 31080. lab/06 and lab/08 say so, and their verifiers read the Knative
# Service's published .status.url rather than assuming the shape.
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
  # …plus whatever the attendee added with `install.sh --add-hosts`.
  cloudbox_extra_hostnames
}

cloudbox_hosts_block() {
  echo "${CLOUDBOX_HOSTS_BEGIN}"
  echo "# CloudBox workshop — the docker substrate has no resolver, so every"
  echo "# hostname is listed here. Written by ./scripts/create-cluster.sh (and"
  echo "# by ./scripts/install.sh --add-hosts / --write-hosts), removed by"
  echo "# ./scripts/destroy-cluster.sh. Safe to delete by hand: nothing outside"
  echo "# these two markers is ever touched."
  local n
  while IFS= read -r n; do echo "127.0.0.1 ${n}"; done < <(cloudbox_hostnames)
  echo "${CLOUDBOX_HOSTS_END}"
}

# The marker-pairing rule, and the two functions that ask about it:
# hosts_markers_paired (quiet predicate) and assert_hosts_block_wellformed
# (same answer, plus the repair guidance). Nothing rewrites
# ${CLOUDBOX_HOSTS_FILE} unless its markers form exactly one ordered pair — or
# none at all.
#
# Both rewrites below are the same awk: "stop printing at the begin marker,
# resume after the end marker". That awk is only exactly-reversible while the
# markers are paired. With a begin marker and NO end marker — a half-finished
# hand edit, an interrupted `sudo tee`, a file someone truncated — it silently
# drops EVERY LINE after the begin marker, and on /etc/hosts that means the
# machine's own `localhost` entry and anything the attendee or their employer's
# MDM put below ours. The block was ours; the rest of the file never was.
#
# So this is a hard stop with manual-repair guidance, not a repair: we cannot
# know where the missing marker belonged, and guessing writes /etc/hosts.
# hosts_markers_paired — the same question, WITHOUT printing anything: 0 when
# the markers are one ordered pair or absent entirely, 1 when they are not.
# Split out so predicates (hosts_block_present) can ask it without narrating,
# while the paths that refuse to write still print the repair guidance below.
# hosts_file_lf — ${CLOUDBOX_HOSTS_FILE} with carriage returns removed. Every
# question about MARKERS is asked through it, because a CRLF hosts file is a
# real WSL2 outcome (Windows tools rewrite it, and `install.sh --print-hosts`
# output pasted from a Windows editor arrives that way) and `grep -xF
# '# cloudbox-begin'` does not match "# cloudbox-begin\r". Every marker check
# then answered "no block here" on a file that has one: --check reported a clean
# file, the tbx staleness check called it clean too, and the writer appended a
# SECOND block whose duplicate markers the next run refuses to touch.
hosts_file_lf() {
  [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] || return 0
  tr -d '\r' < "${CLOUDBOX_HOSTS_FILE}"
}

hosts_markers_paired() {
  [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] || return 0
  local begins ends b_line e_line
  begins="$(hosts_file_lf | grep -cxF "${CLOUDBOX_HOSTS_BEGIN}" || true)"
  ends="$(hosts_file_lf | grep -cxF "${CLOUDBOX_HOSTS_END}" || true)"
  [[ "${begins}" == "0" && "${ends}" == "0" ]] && return 0
  [[ "${begins}" == "1" && "${ends}" == "1" ]] || return 1
  b_line="$(hosts_file_lf | grep -nxF "${CLOUDBOX_HOSTS_BEGIN}" | cut -d: -f1)"
  e_line="$(hosts_file_lf | grep -nxF "${CLOUDBOX_HOSTS_END}" | cut -d: -f1)"
  [[ "${e_line}" -gt "${b_line}" ]]
}

assert_hosts_block_wellformed() {
  [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] || return 0
  hosts_markers_paired && return 0
  local begins ends
  begins="$(hosts_file_lf | grep -cxF "${CLOUDBOX_HOSTS_BEGIN}" || true)"
  ends="$(hosts_file_lf | grep -cxF "${CLOUDBOX_HOSTS_END}" || true)"
  if [[ "${begins}" != "1" || "${ends}" != "1" ]]; then
    fail "${CLOUDBOX_HOSTS_FILE} has ${begins} '${CLOUDBOX_HOSTS_BEGIN}' marker(s) and ${ends} '${CLOUDBOX_HOSTS_END}' marker(s) — expected one of each."
    warn "Refusing to rewrite it: with unpaired markers the rewrite would delete every line"
    warn "after the begin marker, including entries this workshop never wrote."
    warn "Fix it by hand (sudo \$EDITOR ${CLOUDBOX_HOSTS_FILE}): keep ONE ${CLOUDBOX_HOSTS_BEGIN} …"
    warn "${CLOUDBOX_HOSTS_END} pair, or delete both markers and the lines between them, then re-run."
    warn "The lines that belong inside: ./scripts/install.sh --print-hosts"
    return 1
  fi
  # Ordered, too: an end marker ABOVE the begin marker makes the awk skip from
  # the begin marker to EOF just as an absent one does.
  local b_line e_line
  b_line="$(hosts_file_lf | grep -nxF "${CLOUDBOX_HOSTS_BEGIN}" | cut -d: -f1)"
  e_line="$(hosts_file_lf | grep -nxF "${CLOUDBOX_HOSTS_END}" | cut -d: -f1)"
  if [[ "${e_line}" -lt "${b_line}" ]]; then
    fail "${CLOUDBOX_HOSTS_FILE} has '${CLOUDBOX_HOSTS_END}' (line ${e_line}) ABOVE '${CLOUDBOX_HOSTS_BEGIN}' (line ${b_line})."
    warn "Refusing to rewrite it — see ./scripts/install.sh --print-hosts for what the block should be."
    return 1
  fi
  return 0
}

# hosts_marked_block — the block as it is in the file today, markers included.
# Empty when there is none. The mirror image of cloudbox_hosts_block(), which is
# the block as it SHOULD be.
# Matched with the CR stripped (a CRLF file still HAS this block), printed raw
# — so a CRLF block is found, and then compares unequal to the block we would
# write, which is exactly right: the writer rewrites it and the CRs are gone.
hosts_marked_block() {
  [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] || return 0
  awk -v b="${CLOUDBOX_HOSTS_BEGIN}" -v e="${CLOUDBOX_HOSTS_END}" \
    '{ l = $0; sub(/\r$/, "", l) }
     l == b { p = 1 } p { print } l == e { p = 0 }' \
    "${CLOUDBOX_HOSTS_FILE}"
}

# hosts_block_present — 0 when the marked block in the file is EXACTLY the block
# cloudbox_hosts_block() would write today (markers a pair included).
#
# "Lists every current name" was the old rule, and it is only half of correct:
# it can only ever detect names that are MISSING. Remove a name from
# ${CLOUDBOX_EXTRA_HOSTS_FILE} (the documented way to stop resolving one) and
# the block still contains every name this function knows about, so it reported
# "already correct" and the stale 127.0.0.1 line stayed in /etc/hosts forever —
# pointing a name the attendee has retired at their own loopback. Comparing the
# whole block makes both directions drift, and the rewrite is idempotent, so the
# stricter predicate costs nothing on the happy path.
#
# The pairing check stays here and not only in the writers: write_hosts_block
# asks this first, and an unpaired block that happened to match used to answer
# "already correct", which skipped the assertion entirely and left the broken
# file in place for the NEXT writer (or a hand edit) to truncate.
#
# What is compared is the ENTRIES — the "127.0.0.1 <name>" lines — and not the
# comment paragraph above them. Byte-comparing the whole block makes the block's
# own prose part of the contract: edit one word of it in this file (round 3 did,
# twice) and every attendee whose block an older create wrote is told their
# hosts file "carries lines that no longer belong", which is a diagnosis of a
# problem they do not have, pointing at lines that are perfectly correct. The
# entries are what resolve names; the comments are commentary.
# hosts_block_text_current() below is the separate, non-failing question.
hosts_block_present() {
  [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] || return 1
  hosts_file_lf | grep -qxF "${CLOUDBOX_HOSTS_BEGIN}" || return 1
  hosts_markers_paired || return 1
  diff -q <(hosts_marked_block | hosts_entry_lines) \
          <(cloudbox_hosts_block | hosts_entry_lines) >/dev/null 2>&1
}

# hosts_entry_lines — filter: keep only the 127.0.0.1 entry lines of a block.
hosts_entry_lines() { grep -E '^[[:space:]]*127\.0\.0\.1[[:space:]]' || true; }

# hosts_block_text_current — 0 when the marked block matches byte-for-byte,
# comments included. Only the entries decide whether the names resolve, so this
# is worth a note ("the block's text is outdated — --write-hosts refreshes it"),
# never a failure.
hosts_block_text_current() {
  [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] || return 1
  diff -q <(hosts_marked_block) <(cloudbox_hosts_block) >/dev/null 2>&1
}

# hosts_loopback_scan — ONE pass over ${CLOUDBOX_HOSTS_FILE}, printing
# "<line number><TAB><CloudBox name><TAB><the line>" for every entry that makes a
# CloudBox name resolve to 127.0.0.1. The single place that decides what "this
# name is in the hosts file" means; hosts_loopback_lines and hosts_missing_names
# are both views of it.
#
# It parses FIELDS, because /etc/hosts does. The rule the file actually follows
# (hosts(5)) is: address first, then ANY NUMBER of names for it — so
#
#     127.0.0.1   localhost gitea.cloudbox.k8s.test
#
# resolves gitea exactly as its own line would. The previous regex anchored the
# name immediately after the address, so that line was invisible to every caller:
# the tbx staleness check called the file clean and then every workshop URL went
# to the attendee's loopback, and `--check` reported the name missing while the
# machine resolved it. Appending a name to the `localhost` line is, of all the
# hand-edits, the most likely one — it is what most /etc/hosts advice on the
# internet tells you to do.
#
# Comments are stripped first: `# 127.0.0.1 gitea…` (a line an attendee disabled
# rather than deleted) resolves nothing, and must not be reported as if it did.
# Only 127.0.0.1 counts — ::1 is a legal way to break the same names, but this
# workshop never writes it, and reporting a line we did not write and cannot
# rewrite would send an attendee editing something unrelated.
hosts_loopback_scan() {
  [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] || return 0
  awk '
    NR == FNR { w = $0; sub(/\r$/, "", w); want[tolower(w)] = 1; next }
    {
      raw = $0
      sub(/\r$/, "", raw)              # a CRLF file must not hide its entries
      line = raw
      sub(/#.*/, "", line)
      n = split(line, f, /[ \t]+/)
      i = (f[1] == "" ? 2 : 1)          # a leading blank makes field 1 empty
      if (f[i] != "127.0.0.1") next
      for (i++; i <= n; i++)
        # DNS is case-insensitive and so is the resolver reading this file:
        # "127.0.0.1 Gitea.CloudBox.k8s.test" resolves the name and must be
        # reported as the entry it is.
        if (tolower(f[i]) in want) print FNR "\t" f[i] "\t" raw
    }
  ' <(cloudbox_hostnames) "${CLOUDBOX_HOSTS_FILE}"
}

# hosts_loopback_lines — every line in the file that points a CloudBox name at
# 127.0.0.1, with line numbers, wherever it sits. Not "inside our block": the
# point is to find the ones OUTSIDE it. Format matches `grep -n` ("N:line"),
# one entry per line even when a line carries several of our names.
# The raw line is everything after the SECOND tab, not $3: a hosts line may
# contain tabs of its own (`127.0.0.1\tlocalhost\tgitea.…` is ordinary), and
# printing $3 truncated it at the first one — so the "here is the line to
# delete" guidance showed the attendee half of the line they had to find.
hosts_loopback_lines() {
  hosts_loopback_scan | awk -F'\t' '
    !seen[$1]++ {
      raw = $0
      sub(/^[^\t]*\t[^\t]*\t/, "", raw)
      print $1 ":" raw
    }'
}

# hosts_block_stale_for_tbx — 0 when this file would break a tbx cluster.
#
# The tbx preflight used to ask "is the begin marker there?", which is the
# question with the narrowest possible answer. What actually breaks tbx is ANY
# 127.0.0.1 line for a CloudBox name, because /etc/hosts is consulted before
# talos-box's resolver — and those lines outlive their markers routinely: an
# attendee who deletes the marker comments by hand and leaves the entries, a
# half-removed block, a copy-paste of `install.sh --print-hosts` output into a
# file that never had markers. Every one of those passed the old check and then
# sent every workshop URL to the attendee's own loopback on a healthy cluster.
#
# So: any marker (paired or not — an unpaired one is its own problem) OR any
# CloudBox name (pins + the attendee's extras) pointing at 127.0.0.1.
hosts_block_stale_for_tbx() {
  [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] || return 1
  hosts_file_lf | grep -qxF "${CLOUDBOX_HOSTS_BEGIN}" && return 0
  hosts_file_lf | grep -qxF "${CLOUDBOX_HOSTS_END}" && return 0
  [[ -n "$(hosts_loopback_lines)" ]]
}

# hosts_missing_names — the names NOT currently resolvable from the file, so a
# FAIL message can name them instead of saying "the block is wrong". The other
# view of hosts_loopback_scan, so "missing" and "stale" cannot disagree about
# what counts as an entry (they did: a name appended to the `localhost` line was
# reported missing while the machine resolved it perfectly well).
hosts_missing_names() {
  local found
  found="$(hosts_loopback_scan | cut -f2)"
  local n
  while IFS= read -r n; do
    grep -qxF "${n}" <<<"${found}" || echo "${n}"
  done < <(cloudbox_hostnames)
}

# write_hosts_block — replace the marked block (or append it). Needs sudo, once.
# Written via a temp file and `sudo tee`, never an in-place sudo sed: a
# half-written /etc/hosts breaks name resolution for the whole machine.
#
# NEVER FATAL, deliberately: 0 on success, 1 on any refusal or failure, and the
# reason is printed either way. It is called at the END of create-cluster.sh,
# after the cluster is proven healthy, and a `die` there threw away a working
# cluster over a name-resolution problem — worse, the ONE recovery an attendee
# would try (re-run create-cluster.sh) is then refused by preflight, because the
# node containers it just built are exactly what preflight looks for. There was
# no re-entrant writer at all: `--add-hosts` needs a name to add.
# `install.sh --write-hosts` is that writer, and it is what every failure below
# names. Callers that want a hard stop check the status themselves.
write_hosts_block() {
  # Pairing FIRST, before the "is it already correct?" shortcut: a file with a
  # begin marker and no end marker can still list every name, and taking the
  # shortcut there would report success on a file we have just refused to touch.
  if ! assert_hosts_block_wellformed; then
    warn "Not touching ${CLOUDBOX_HOSTS_FILE} (see above). The cluster is fine; only the hostnames are."
    warn "Fix the markers by hand, then: ./scripts/install.sh --write-hosts"
    return 1
  fi
  # Byte-identical, not merely "the same names": the writer is the one place
  # that can refresh an outdated comment paragraph, and `--check` tells the
  # attendee it does. Everywhere the difference DECIDES something —
  # hosts_block_present, and so every FAIL — only the entries count.
  hosts_block_text_current && { ok "${CLOUDBOX_HOSTS_FILE} block already correct"; return 0; }
  local tmp; tmp="$(mktemp)"
  # Set AFTER mktemp so an early `return 0` above never runs it with tmp unset.
  # shellcheck disable=SC2064  # expand tmp NOW: at RETURN time the local is gone
  trap "rm -f '${tmp}'" RETURN
  if [[ -r "${CLOUDBOX_HOSTS_FILE}" ]]; then
    awk -v b="${CLOUDBOX_HOSTS_BEGIN}" -v e="${CLOUDBOX_HOSTS_END}" \
      '{ l = $0; sub(/\r$/, "", l) }
       l == b { skip = 1 } !skip { print } l == e { skip = 0 }' \
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
    fail "Could not write ${CLOUDBOX_HOSTS_FILE} (sudo declined or unavailable)."
    warn "Nothing else is affected — this is only name resolution. Two ways back:"
    warn "  ./scripts/install.sh --write-hosts   # try again (asks for sudo)"
    warn "  ./scripts/install.sh --print-hosts   # the lines, to add by hand"
    return 1
  fi
  rm -f "${tmp}"
  # The temp file is gone; disarm the trap so the RETURN below is not a second
  # `rm -f` against a path $TMPDIR may by then have handed to someone else.
  trap - RETURN
  if ! hosts_block_present; then
    fail "Wrote ${CLOUDBOX_HOSTS_FILE} but the block is still not what it should be — check it by hand"
    warn "  ./scripts/install.sh --print-hosts   # what belongs there"
    return 1
  fi
  ok "${CLOUDBOX_HOSTS_FILE} updated ($(cloudbox_hostnames | wc -l | tr -d ' ') names)"
}

# remove_hosts_block — take the marked block out again. NEVER FATAL (see the
# sudo branch at the bottom): it runs at the end of a destroy, where the cluster
# is already gone and dying here would skip the mirror purge and the summary.
# 0 when there is nothing to do or the block was removed, 1 when the file still
# carries CloudBox lines and the caller should say so.
remove_hosts_block() {
  [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] || return 0
  # EITHER marker, not just the begin one. An end-only file is precisely the
  # state the assertion below exists for — a truncated block, a half-finished
  # hand edit — and keying the whole function on the begin marker made it return
  # "nothing to do" there, silently, with the broken file left for the next
  # writer to refuse (or for a hand edit to truncate).
  hosts_file_lf | grep -qxF "${CLOUDBOX_HOSTS_BEGIN}" \
    || hosts_file_lf | grep -qxF "${CLOUDBOX_HOSTS_END}" \
    || return 0
  # Same guard as write_hosts_block, and NOT fatal here: this runs on the
  # teardown path, where dying would abort a destroy over a file the destroy
  # does not need. The block stays; the message says how to remove it.
  if ! assert_hosts_block_wellformed; then
    warn "Leaving ${CLOUDBOX_HOSTS_FILE} alone — remove the CloudBox lines by hand."
    # Name them. "Remove the CloudBox lines" is advice an attendee can only
    # follow if they know which lines those are, and this is precisely the file
    # where guessing is expensive. These are also the lines a later tbx create
    # dies on (hosts_block_stale_for_tbx), so printing them here is the same
    # list, one destroy earlier.
    local stray; stray="$(hosts_loopback_lines)"
    if [[ -n "${stray}" ]]; then
      warn "These lines point CloudBox names at your loopback (line: text):"
      printf '   %s\n' "${stray}"
    fi
    return 1
  fi
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
    # NOT a die. By the time this runs the cluster is already destroyed, and
    # dying here skipped everything after it — the mirror purge, the extras
    # file, and the summary that tells the attendee what state they are in.
    # A declined sudo password is a hosts-file problem, not a teardown failure.
    fail "Could not rewrite ${CLOUDBOX_HOSTS_FILE} (sudo declined or unavailable)."
    warn "The cluster is gone; only these name entries are left behind:"
    local left; left="$(hosts_loopback_lines)"
    [[ -n "${left}" ]] && printf '   %s\n' "${left}"
    warn "Delete the lines between ${CLOUDBOX_HOSTS_BEGIN} and ${CLOUDBOX_HOSTS_END} by hand"
    warn "(sudo \$EDITOR ${CLOUDBOX_HOSTS_FILE}) — on the tbx substrate they would override its resolver."
    return 1
  fi
  rm -f "${tmp}"
  trap - RETURN   # see write_hosts_block
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
