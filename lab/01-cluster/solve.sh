#!/usr/bin/env bash
# Module 01 — full solution: create the cluster. (The exploration part of the
# module has no machine state to produce; verify.sh checks the cluster itself.)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Idempotent: solve.sh's contract is "produce the module's end state", and it
# may already exist (re-runs, CI, catch-up) — create-cluster.sh itself refuses
# to run against an existing cluster. Found by rehearsal-in-CI run 5.
# Substrate-aware for the same reason verify.sh is: "does a cluster already
# exist" is a question about containers on docker and about VMs on tbx. Each
# branch asks it exactly the way that substrate's own backend guard does
# (scripts/substrate/{docker,tbx}.sh), so this guard and create-cluster.sh can
# never disagree. Resolved inline rather than by sourcing scripts/lib.sh, which
# would also drag in the ordering this file deliberately controls below.
# docker: -aq (not -q) matches stopped containers too — otherwise a stopped
# cluster would slip past this guard and make create-cluster.sh die.
SUBSTRATE="${CLOUDBOX_SUBSTRATE:-}"
if [[ -z "$SUBSTRATE" && -r "$HOME/.cloudbox/substrate" ]]; then
  SUBSTRATE="$(tr -d '[:space:]' < "$HOME/.cloudbox/substrate")"
fi
case "$SUBSTRATE" in tbx|docker) ;; *) SUBSTRATE=docker ;; esac

cluster_exists() {
  if [[ "$SUBSTRATE" == tbx ]]; then
    tbx status cloudbox >/dev/null 2>&1
  else
    [[ -n "$(docker ps -aq --filter "label=talos.cluster.name=cloudbox" 2>/dev/null)" ]]
  fi
}

# "Exists" is not one state on tbx. A cluster whose VMs are ALL stopped or
# suspended — a reboot, a `tbx down`, a laptop closed at the end of the day — is
# a cluster to START, and "skipping creation" there left this script waiting 300
# seconds for nodes that were powered off, then failing. The preflight and
# lab/01's verify.sh already know that state; this asks the same predicate
# rather than a fourth copy of the jq: tbx_cluster_all_stopped (it lives in the
# tbx backend, next to the create path that uses it), run in a sub-bash so
# neither lib.sh's nor the backend's definitions land in this shell — the
# substrate resolution above stays inline on purpose, and sourcing a create
# backend here must not be able to change what this script does.
tbx_all_stopped() {
  bash -c 'source "$1/scripts/lib.sh" >/dev/null 2>&1
           source "$1/scripts/substrate/tbx.sh" >/dev/null 2>&1
           tbx_cluster_all_stopped' _ "$REPO_ROOT"
}

# Which verb brings it back — same helper, same reason: `start` on a SUSPENDED
# cluster cold-boots it and throws away the saved memory, so a script that
# always says "start" quietly costs the attendee the suspend they took.
tbx_verb() {
  bash -c 'source "$1/scripts/lib.sh" >/dev/null 2>&1
           source "$1/scripts/substrate/tbx.sh" >/dev/null 2>&1
           tbx_restart_verb' _ "$REPO_ROOT"
}

if cluster_exists; then
  if [[ "$SUBSTRATE" == tbx ]] && tbx_all_stopped; then
    VERB="$(tbx_verb)"
    echo "cloudbox VMs exist but are all stopped/suspended — 'tbx cluster ${VERB}', not re-creating."
    tbx cluster "$VERB" cloudbox
    # The VM addresses are vmnet DHCP leases and may have moved while the
    # cluster was down; this repoints the kubeconfig, the talosconfig context
    # and ~/.cloudbox/api-endpoint at where the control plane came back.
    "$REPO_ROOT/scripts/create-cluster.sh" --refresh-endpoint
  else
    echo "cloudbox cluster already exists (${SUBSTRATE}) — skipping creation."
  fi
else
  "$REPO_ROOT/scripts/create-cluster.sh"
fi

# Guard AFTER the branch above, not before it: on a fresh machine there is no
# cluster and no workshop context yet — creating them is this script's job.
# create-cluster.sh selects admin@cloudbox itself; the "already exists" branch
# selects nothing, which is exactly the case the guard has to catch before the
# kubectl below runs against someone else's cluster.
# shellcheck source=../common.sh
source "$REPO_ROOT/lab/common.sh"

# Wait for both nodes to be Ready (Cilium needs a moment after bootstrap).
kubectl wait --for=condition=Ready nodes --all --timeout=300s
