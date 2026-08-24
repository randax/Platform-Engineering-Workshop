#!/usr/bin/env bash
# =============================================================================
# destroy-cluster.sh — tear down the CloudBox Talos cluster
#
# Destroys the Talos docker cluster and removes its kubeconfig entries.
# The cloudbox-mirror image registry is left running (it is expensive to
# refill) unless you pass --purge-mirror.
#
# Usage:
#   ./scripts/destroy-cluster.sh                 # destroy the cluster
#   ./scripts/destroy-cluster.sh --purge-mirror  # also remove mirror + volume
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

PURGE_MIRROR="false"
[[ "${1:-}" == "--purge-mirror" ]] && PURGE_MIRROR="true"

need talosctl

# DELIBERATELY NOT guarded — the one script in scripts/ that must keep working
# when kubectl points at the wrong cluster, because that is the state it exists
# to clean up (and, per docs/HAZARDS.md, the state it CAUSES: removing the
# workshop kubeconfig entries is what makes kubectl fall through to the next
# ~/.kube/config entry). Guarding it would also break `catch-up.sh --rebuild`,
# whose first act is to destroy.
#
# Safe to leave unguarded because nothing here is resolved through the current
# context: `talosctl cluster destroy --name` only touches docker containers
# labelled talos.cluster.name=${CLUSTER_NAME}, and the kubectl calls below are
# `kubectl config` edits of NAMED entries (admin@${CLUSTER_NAME} and friends) —
# local kubeconfig surgery, not API calls. This script cannot delete a foreign
# cluster's resources; the CI recovery-path job asserts exactly that by proving
# an unrelated context survives a destroy.

# The substrate the cluster was CREATED on, not the one this machine would
# detect today: a laptop that has lost `tbx doctor` since the create must still
# be told to destroy VMs, not to look for docker containers that never existed.
SUBSTRATE="$(substrate_resolve)"
info "Substrate: ${SUBSTRATE} (from ${CLOUDBOX_SUBSTRATE_FILE})"
# `need docker` only where the backend actually needs it — a tbx machine has no
# reason to have the docker CLI. Written as an `if`, not `[[ … ]] && need docker`:
# under `set -e` a failing test as a whole statement kills the script.
if [[ "${SUBSTRATE}" == "docker" ]]; then
  need docker
fi
# shellcheck source=substrate/docker.sh
source "${SCRIPT_DIR}/substrate/${SUBSTRATE}.sh"
substrate_destroy
rm -f "${CLOUDBOX_SUBSTRATE_FILE}"

# --- Clean up kubeconfig / talosconfig contexts (best effort) -----------------
# Cleaned in EVERY file the workshop could have written to, not just the one in
# effect right now. mise.toml pins KUBECONFIG to ~/.kube/cloudbox.conf for this
# repo, but two things put ${CLUSTER_NAME} entries in ~/.kube/config anyway:
# an attendee who never activated mise (the pin never reached them), and anyone
# who created a cluster before the pin existed. A left-behind admin@${CLUSTER_NAME}
# in ~/.kube/config is exactly the entry the context guard is built to accept,
# so leaving it there would re-arm the fall-through the pin exists to disarm.
#
# ${CLOUDBOX_KUBECONFIG} is listed EXPLICITLY rather than left to
# kubeconfig_in_use(), which returns $KUBECONFIG whenever that is set and only
# falls through to the pinned file when it is not. That is one case short: a
# mise SHIM overrides an inherited KUBECONFIG (the same precedence docs/HAZARDS.md
# records as "a KUBECONFIG= prefix does nothing to a mise-shimmed kubectl"), so a
# shell that exports KUBECONFIG=~/.kube/config — a .zshrc export, or mise
# activated at $HOME where the user-level [env] sets it — creates the cluster in
# cloudbox.conf and would have cleaned ~/.kube/config. The stale admin@cloudbox
# left behind is on 127.0.0.1:<port>, i.e. precisely what the context guard
# accepts, so every later module diagnoses "you have no cluster" as "you forgot
# to push". Nonexistent files are skipped below, so this is a no-op for anyone
# who never had a pinned kubeconfig.
#
# Still only NAMED-entry surgery — no cluster is contacted, nothing that is not
# this workshop's own context/cluster/user is touched — which is the premise
# check-consistency.sh check 8 asserts to keep this script unguarded.
if have kubectl; then
  cleaned=()
  for kc in "$(kubeconfig_in_use)" "${CLOUDBOX_KUBECONFIG}" "${HOME}/.kube/config"; do
    [[ -f "${kc}" ]] || continue
    # Same path twice (the usual non-mise case) — clean it once.
    for seen in "${cleaned[@]+"${cleaned[@]}"}"; do [[ "${seen}" == "${kc}" ]] && continue 2; done
    kubectl --kubeconfig="${kc}" config delete-context "admin@${CLUSTER_NAME}" >/dev/null 2>&1 || true
    kubectl --kubeconfig="${kc}" config delete-cluster "${CLUSTER_NAME}" >/dev/null 2>&1 || true
    kubectl --kubeconfig="${kc}" config delete-user "admin@${CLUSTER_NAME}" >/dev/null 2>&1 || true
    cleaned+=("${kc}")
  done
  ok "kubeconfig entries removed (${cleaned[*]})"
fi
# `talosctl config remove` SKIPS the context that is currently selected — and
# still exits 0 while saying so ("skipping removal of current context ...,
# please change it to another before removing"). create-cluster.sh always
# leaves '${CLUSTER_NAME}' selected, so the bare call here silently removed
# nothing, undetectably. The next create-cluster.sh then found the name taken,
# `talosctl cluster create` renamed the NEW context to '${CLUSTER_NAME}-1', and
# every `talosctl --context ${CLUSTER_NAME}` in create-cluster.sh talked to the
# cluster that had just been destroyed:
#   error copying: rpc error: ... dial tcp 127.0.0.1:53556: connect: connection refused
# i.e. destroy + create (and `catch-up.sh --rebuild`) failed on the second
# cluster of the day. So: switch away from it first, then remove.
talos_contexts() { # -> one context name per line, '*' marker stripped
  talosctl config contexts 2>/dev/null | awk 'NR > 1 { print ($1 == "*") ? $2 : $1 }'
}
# Matched with pipe-free bash, NOT `talos_contexts | grep`. Under
# `set -euo pipefail` the two greps this replaces were one live bug and one
# latent one:
#
#   `other="$(talos_contexts | grep -vx "${CLUSTER_NAME}" | head -1)"` — when
#   '${CLUSTER_NAME}' is the ONLY context, grep -vx matches nothing and exits 1.
#   A bare assignment inherits its command substitution's status, so `set -e`
#   killed the script HERE, before the single-context branch below — the branch
#   that exists for precisely that case — could run. `catch-up.sh --rebuild`
#   then died mid-destroy, having removed the kubeconfig entries but never
#   recreating anything. One cluster and one context is the normal attendee
#   state, so the documented recovery command was broken for everyone whose
#   machine had nothing else in ~/.talos/config. Caught by the CI recovery-path
#   job, which is a fresh runner and therefore always the one-context case.
#
#   `talos_contexts | grep -qx "${CLUSTER_NAME}"` — LATENT, not observed: grep
#   -q exits at the first match, and if awk is still writing it takes EPIPE,
#   which pipefail turns into a non-zero pipeline — i.e. a context that IS
#   present reads as absent and the removal is skipped, silently. Measured, it
#   needs ~5000 contexts before awk's output stops fitting in one pipe buffer,
#   so nobody was ever going to hit it. Rewritten anyway: the fix for the live
#   bug above is a pipe-free matcher, and leaving one grep behind would keep
#   the class alive for the next person who copies the line.
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
if has_talos_context "${CLUSTER_NAME}"; then
  other="$(first_other_talos_context "${CLUSTER_NAME}")"
  if [[ -n "${other}" ]]; then
    talosctl config context "${other}" >/dev/null 2>&1 || true
    talosctl config remove "${CLUSTER_NAME}" --noconfirm >/dev/null 2>&1 || true
  else
    # Only one context, and it is the cluster we just destroyed: the whole
    # talosconfig describes nothing that still exists. talosctl recreates it on
    # the next cluster create.
    rm -f "${TALOSCONFIG:-${HOME}/.talos/config}"
  fi
fi
if has_talos_context "${CLUSTER_NAME}"; then
  warn "talosconfig still has a '${CLUSTER_NAME}' context — remove it before recreating:"
  warn "  talosctl config context <other> && talosctl config remove ${CLUSTER_NAME}"
else
  ok "talosconfig context removed"
fi

# --- Mirror ---------------------------------------------------------------------
if [[ "${PURGE_MIRROR}" == "true" ]]; then
  step "Purging the image mirror"
  docker rm -f "${MIRROR_NAME}" >/dev/null 2>&1 || true
  docker volume rm "${MIRROR_VOLUME}" >/dev/null 2>&1 || true
  ok "Mirror container and volume removed (re-run ./scripts/cloudbox-init.sh to refill)"
else
  info "Image mirror kept (pass --purge-mirror to remove it)"
fi

echo
ok "Done. Recreate with: ./scripts/create-cluster.sh"
