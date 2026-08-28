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
# never disagree. The DECISION comes from scripts/substrate-decide.sh (below) —
# not from scripts/lib.sh, whose sourcing would drag in the ordering this file
# deliberately controls further down.
# docker: -aq (not -q) matches stopped containers too — otherwise a stopped
# cluster would slip past this guard and make create-cluster.sh die.
# The substrate decision is scripts/substrate-decide.sh — the SINGLE
# implementation, sourced rather than copied. Three files carried their own
# `case "$SUBSTRATE" in tbx|docker) ;; *) SUBSTRATE=docker ;; esac` ladder, and
# copies drift: this one had no `kind` arm for a while, and lab 00's had no
# platform gate at all, so the same laptop was graded on two different
# substrates by two different scripts. substrate-decide.sh is deliberately
# logging-neutral — it never calls ok/fail/warn/die and never exits — which is
# what lets a verifier with its own counting ok()/fail() source it safely.
# `|| SUBSTRATE=docker` covers the one failing case: an invalid
# CLOUDBOX_SUBSTRATE, which lib.sh reports in its own voice and this file has no
# business dying over.
# shellcheck source=../../scripts/substrate-decide.sh
. "${REPO_ROOT}/scripts/substrate-decide.sh"
SUBSTRATE=""
substrate_decide_into SUBSTRATE || SUBSTRATE=docker

# The kind lifeboat, BEFORE cluster_exists() — which asks about Talos containers
# and would answer "no", sending this straight into ./scripts/create-cluster.sh,
# which refuses on this identity (require_identity_match / the kind arm). The
# ladder above used to collapse kind to docker, so `catch-up.sh 01` and every
# solve/verify CI pairing exited 1 on a lifeboat machine whose cluster is up and
# working exactly as documented.
#
# Mirrors verify.sh: nothing to produce, nothing to fix, exit 0. The lifeboat's
# promise is that modules 02 onward are identical; module 01's Talos content is
# the whole price of taking it.
if [[ "$SUBSTRATE" == kind ]]; then
  echo "🛟 kind lifeboat: module 01 has no end state to produce here — it builds a Talos"
  echo "   cluster, and this one is kind (./scripts/kind-fallback.sh). That is the"
  echo "   documented trade-off; modules 02 onward are identical."
  echo "   Your cluster: kubectl get nodes   ·   teardown: ./scripts/kind-fallback.sh --delete"
  exit 0
fi

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

# The documented lab-01 start is `create-cluster.sh --skip-cilium`, so "already
# exists" usually means "exists WITHOUT a CNI" — and waiting for Ready on that
# hung 300 s and failed. Install the same Cilium create-cluster.sh would have
# (cilium_install, scripts/lib.sh, in a sub-bash for the reason tbx_all_stopped
# is), then on tbx run the post step the README teaches — the LB pool, the L2
# policy and the .200 proof — which is what lab 01's verify.sh checks.
if ! kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
  echo "no CNI on this cluster (created with --skip-cilium) — installing Cilium the way create-cluster.sh does"
  bash -c 'SCRIPT_DIR="$1/scripts"; source "$1/scripts/lib.sh" >/dev/null 2>&1
           cilium_install "$2"' _ "$REPO_ROOT" "$SUBSTRATE"
  if [[ "$SUBSTRATE" == tbx ]]; then
    "$REPO_ROOT/scripts/create-cluster.sh" --post-cni
  fi
fi

# Wait for both nodes to be Ready (Cilium needs a moment after bootstrap).
kubectl wait --for=condition=Ready nodes --all --timeout=300s
