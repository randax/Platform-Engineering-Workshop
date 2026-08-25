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

if cluster_exists; then
  echo "cloudbox cluster already exists (${SUBSTRATE}) — skipping creation."
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
