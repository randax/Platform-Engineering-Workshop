#!/usr/bin/env bash
# Module 01 — full solution: create the cluster. (The exploration part of the
# module has no machine state to produce; verify.sh checks the cluster itself.)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Idempotent: solve.sh's contract is "produce the module's end state", and it
# may already exist (re-runs, CI, catch-up) — create-cluster.sh itself refuses
# to run against an existing cluster. Found by rehearsal-in-CI run 5.
# -aq (not -q): match stopped containers too, so we agree with
# create-cluster.sh's own "already exists" check (it uses -aq) — otherwise a
# stopped cluster would slip past this guard and make create-cluster.sh die.
if [[ -n "$(docker ps -aq --filter "label=talos.cluster.name=cloudbox" 2>/dev/null)" ]]; then
  echo "cloudbox cluster already exists — skipping creation."
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
