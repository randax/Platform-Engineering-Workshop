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
need docker

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

step "Destroying Talos cluster '${CLUSTER_NAME}'"
# Talos labels every node container with talos.cluster.name=<cluster>
if [[ -n "$(docker ps -aq --filter "label=talos.cluster.name=${CLUSTER_NAME}")" ]]; then
  talosctl cluster destroy --name "${CLUSTER_NAME}" --force
  ok "Cluster destroyed"
else
  warn "No '${CLUSTER_NAME}' cluster found — nothing to destroy"
fi

# --- Clean up kubeconfig / talosconfig contexts (best effort) -----------------
if have kubectl; then
  kubectl config delete-context "admin@${CLUSTER_NAME}" >/dev/null 2>&1 || true
  kubectl config delete-cluster "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  kubectl config delete-user "admin@${CLUSTER_NAME}" >/dev/null 2>&1 || true
  ok "kubeconfig entries removed"
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
if talos_contexts | grep -qx "${CLUSTER_NAME}"; then
  other="$(talos_contexts | grep -vx "${CLUSTER_NAME}" | head -1)"
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
if talos_contexts | grep -qx "${CLUSTER_NAME}"; then
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
