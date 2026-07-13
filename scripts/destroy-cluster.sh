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
talosctl config remove "${CLUSTER_NAME}" --noconfirm >/dev/null 2>&1 || true

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
