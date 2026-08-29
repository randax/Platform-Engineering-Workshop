#!/usr/bin/env bash
# =============================================================================
# substrate-decide.sh — WHICH SUBSTRATE, and nothing else.
#
# Sourced by scripts/lib.sh and by lab/00-setup/verify.sh. It exists because
# those two had two copies of the same decision and the copies drifted: lab 00
# cased on `uname -m` (wrong in a Rosetta shell) and applied no platform gate at
# all, so a laptop that create-cluster.sh puts on tbx was graded as docker — and
# the grader is the thing that tells an attendee they are ready.
#
# Contract for everything in here, because lab/00-setup/verify.sh cannot afford
# anything else:
#   * PURE. Every function PRINTS its answer (or sets a named variable) and
#     returns a status. Nothing here calls ok/fail/warn/die, writes a file, or
#     exits — lab 00 defines its own COUNTING ok()/fail() and must run every
#     check, so a helper that narrates or exits would break it.
#   * No `set -e`, no traps, no side effects at source time beyond defining
#     functions and the two memo variables.
#   * Read-only with respect to the machine: the only external command that is
#     not a pure query is `tbx doctor`, which is itself read-only.
#
# lib.sh keeps the DIAGNOSTICS (the messages for an invalid override, a corrupt
# state file, "why not tbx") and delegates the decision here. Do not copy any of
# this into a caller — that is the bug this file was extracted to end.
# =============================================================================

# The file substrate_persist() writes: the substrate the cluster on this machine
# was actually CREATED on. Defined here, not in lib.sh, because lab 00 reads it
# through substrate_decide() without sourcing lib.sh at all.
: "${CLOUDBOX_SUBSTRATE_FILE:=${HOME}/.cloudbox/substrate}"

# --- Architecture -------------------------------------------------------------
# detect_arch — prints amd64 or arm64, fails on anything else.
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) return 1 ;;
  esac
}

# host_cpu_arch — the arch of the MACHINE, not of this shell. On macOS the two
# differ inside Rosetta: a terminal launched with "Open using Rosetta" (or any
# shell under an x86_64 parent — some IDEs, older brew installs) reports
# `uname -m` = x86_64 on an Apple Silicon Mac. The tbx VMs are virtualised
# natively by that hardware and are arm64 regardless, so asking uname there
# mirrored the whole image set for the wrong architecture — offline, at the
# venue, with "exec format error" as the only clue.
#
# `sysctl -n hw.optional.arm64` is not translated: it describes the CPU, and
# answers 1 under Rosetta as well as outside it. Absent (or 0) means a real
# Intel Mac, where uname is right. Everything non-Darwin falls through to
# detect_arch — Linux has no equivalent translation layer here.
host_cpu_arch() {
  if [ "$(uname -s)" = "Darwin" ]; then
    [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = "1" ] && { echo "arm64"; return 0; }
  fi
  detect_arch
}

# --- tbx doctor ---------------------------------------------------------------
# tbx_doctor_run — `tbx doctor`, ONCE per process. Output in TBX_DOCTOR_OUT,
# verdict in the return status. `tbx doctor` probes the helper, DNS, the routes
# and the mirror; it is the slowest read-only thing this repo runs, and it was
# being run three times over in a single `install.sh --check`. Callers that want
# to SHOW it print TBX_DOCTOR_OUT.
#
# Memoised for the life of the process, which is the right scope: every caller
# is within seconds of the others, and nothing here can change the verdict. The
# memo is why the _into forms below exist: a command substitution is a subshell,
# and the memo dies with it.
# shellcheck disable=SC2034  # printed by install.sh --check and lib.sh's
# substrate_doctor_reason, both of which source this file.
TBX_DOCTOR_OUT=""
TBX_DOCTOR_RC=""
tbx_doctor_run() {
  if [ -z "${TBX_DOCTOR_RC}" ]; then
    # shellcheck disable=SC2034  # read by install.sh --check and lib.sh
    if TBX_DOCTOR_OUT="$(tbx doctor 2>&1)"; then TBX_DOCTOR_RC=0; else TBX_DOCTOR_RC=1; fi
  fi
  [ "${TBX_DOCTOR_RC}" = "0" ]
}

# --- The three identities -----------------------------------------------------
# tbx and docker are the two SUBSTRATES: create-cluster.sh builds on one of
# them and destroy-cluster.sh tears down whichever the state file names.
#
# `kind` is the third, and it is not a substrate — it is the lifeboat
# (scripts/kind-fallback.sh), which meets the docker substrate's ingress and
# /etc/hosts contract on a cluster neither create-cluster.sh nor
# destroy-cluster.sh can touch. It became a PERSISTED identity because the
# alternative was worse: with nothing in this file, every helper that keys on it
# — install.sh --check, the mirror architecture, the host gateway, lab 00 —
# silently graded a lifeboat machine as "docker" and gave it Talos-in-Docker
# answers, and `destroy-cluster.sh` fell back to docker and started removing the
# /etc/hosts block of a cluster that was still running.
#
# Detection never yields it (substrate_decide_detect_into below): nothing about
# a machine says "this one should use the lifeboat". It is a decision a person
# makes, and kind-fallback.sh records it after the cluster exists.
substrate_valid() { # <value>
  case "${1:-}" in tbx|docker|kind) return 0 ;; *) return 1 ;; esac
}

# The two the machine may be judged to be. Kept separate from substrate_valid so
# that "kind is persisted but never detected" is a rule with a name.
substrate_detectable() { # <value>
  case "${1:-}" in tbx|docker) return 0 ;; *) return 1 ;; esac
}

# substrate_persisted_raw — the state file's content with whitespace stripped,
# or nothing. No validation, no narration: substrate_current() in lib.sh needs
# the raw value to name it in its warning.
substrate_persisted_raw() {
  [ -r "${CLOUDBOX_SUBSTRATE_FILE}" ] || return 0
  tr -d '[:space:]' < "${CLOUDBOX_SUBSTRATE_FILE}"
}

# --- Detection ----------------------------------------------------------------
# substrate_platform_supported — can talos-box run here at all? It virtualises
# natively (vz/hvf on macOS, KVM on Linux), so the answer is a property of the
# OS and the CPU and nothing else.
#
# The arch comes from host_cpu_arch(), NOT `uname -m`: a Rosetta shell on an
# Apple Silicon Mac reports x86_64, which is not a supported pair, and quietly
# selected docker on a machine whose `tbx doctor` passes and whose VMs are
# natively virtualised arm64. The Linux aliases stay as a belt on a helper that
# could grow another caller; host_cpu_arch can no longer produce them.
substrate_platform_supported() {
  local os arch
  os="$(uname -s)"; arch="$(host_cpu_arch 2>/dev/null || true)"
  case "${os}:${arch}" in
    Darwin:arm64|Linux:x86_64|Linux:aarch64|Linux:arm64|Linux:amd64) return 0 ;;
    *) return 1 ;;
  esac
}

# substrate_decide_detect_into <varname> — the substrate this MACHINE can run,
# with no persisted answer and no override. tbx needs its daemon+helper
# installed and healthy, so `tbx doctor` (which exits non-zero on any FAIL —
# cmd/tbx/doctor.go: `return errors.New("one or more doctor checks failed")`) is the gate, not the mere presence of the binary.
# Always sets the variable; always returns 0. Only ever `tbx` or `docker` —
# substrate_detectable is the rule, and `kind` is deliberately not in it.
substrate_decide_detect_into() { # <varname>
  printf -v "$1" '%s' "docker"
  command -v tbx >/dev/null 2>&1 || return 0
  substrate_platform_supported || return 0
  if tbx_doctor_run; then printf -v "$1" '%s' "tbx"; fi
  return 0
}

substrate_decide_detect() {
  local __sd_detected; substrate_decide_detect_into __sd_detected; echo "${__sd_detected}"
}

# --- The whole decision -------------------------------------------------------
# substrate_decide_into <varname> — the identity to USE right now, in precedence
# order:
#   1. an explicit CLOUDBOX_SUBSTRATE in the environment (the documented escape
#      hatch, e.g. CLOUDBOX_SUBSTRATE=tbx on a machine that failed detection —
#      and CLOUDBOX_SUBSTRATE=kind for a lifeboat session whose state file was
#      lost, since nothing detects the lifeboat)
#   2. the persisted answer from a previous create, or from kind-fallback.sh
#   3. detection, floored by CLOUDBOX_SUBSTRATE_DEFAULT: when the default is
#      "docker" (the go-live gate having flipped it), detection never upgrades.
#
# Returns 1 WITHOUT setting the variable when CLOUDBOX_SUBSTRATE holds something
# that is not one of the accepted values; the caller says so in its own voice. A state
# file with junk in it is treated as no answer (also the caller's to report),
# because a machine is not stopped by a corrupt note about the past.
#
# RESERVED variable names for callers of the _into forms: __sd_result_ref and
# __sd_persisted. A `local` here SHADOWS a caller variable of the same name, so
# `substrate_decide_into __var` used to set THIS function's local `__var` and
# leave the caller's own untouched — no error, no warning, an empty answer that
# every caller then read as "docker". The names are deliberately unlikely; the
# rule is that nothing outside this file may pass one of them as <varname>.
substrate_decide_into() { # <varname>
  local __sd_result_ref="$1" __sd_persisted
  if [ -n "${CLOUDBOX_SUBSTRATE:-}" ]; then
    substrate_valid "${CLOUDBOX_SUBSTRATE}" || return 1
    printf -v "${__sd_result_ref}" '%s' "${CLOUDBOX_SUBSTRATE}"
    return 0
  fi
  __sd_persisted="$(substrate_persisted_raw)"
  if substrate_valid "${__sd_persisted}"; then
    printf -v "${__sd_result_ref}" '%s' "${__sd_persisted}"
    return 0
  fi
  if [ "${CLOUDBOX_SUBSTRATE_DEFAULT:-tbx}" = "docker" ]; then
    printf -v "${__sd_result_ref}" '%s' "docker"
    return 0
  fi
  substrate_decide_detect_into "${__sd_result_ref}"
}

substrate_decide() {
  local __sd_answer
  substrate_decide_into __sd_answer || return 1
  echo "${__sd_answer}"
}
