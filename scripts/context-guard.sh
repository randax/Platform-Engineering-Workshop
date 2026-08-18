#!/usr/bin/env bash
# =============================================================================
# context-guard.sh — the workshop-context guard, defined in ONE place.
#
# Source me, don't run me. Sourcing DEFINES the guard; it does not call it.
# Callers decide where the call belongs, because the two halves of this repo
# need it in different places:
#
#   * lab/common.sh sources this and calls require_workshop_context immediately
#     — every lab script passes through common.sh, so none can forget it.
#   * scripts/lib.sh sources this and calls NOTHING. create-cluster.sh and
#     kind-fallback.sh source lib.sh and legitimately run BEFORE any workshop
#     context exists — they are what create it — so a source-time call there
#     would make the workshop impossible to start. Each script in scripts/
#     calls the guard explicitly, after its own create/rebuild branch. Which
#     scripts, and why the rest are exempt, is enforced by check-consistency.sh.
#
# This file lives in scripts/ rather than lab/ because scripts/ cannot source
# lab/ (the labs are the optional half), and it is separate from lib.sh because
# lab/common.sh must NOT pull lib.sh in wholesale: lib.sh defines ok() and
# fail(), and lab/01-cluster/verify.sh defines its own counting fail() BEFORE
# it sources common.sh — lib.sh's non-counting version would silently clobber
# it and the module would report failures while exiting 0.
#
# =============================================================================
# Fail closed; never touch someone else's cluster.
#
# Every helper in lab/common.sh and every kubectl call in scripts/ talks to
# "whatever cluster kubectl currently points at". That is harmless on a laptop
# with one cluster and dangerous on the laptops this workshop is for, whose
# owners arrive with a dozen contexts. Rehearsal 3 reproduced it on the ordinary
# attendee path: destroy-cluster.sh removes the admin@cloudbox kubeconfig
# entries, the current context falls through to the next entry in the same
# ~/.kube/config, and lab/01-cluster/verify.sh then printed "✅ kubectl reaches
# the API server" and "want 2 Ready nodes, have 36/36" — against a real 36-node
# corporate cluster. verify.sh is read-only, so nothing was harmed; solve.sh,
# inject.sh, restore.sh and every script in scripts/ are not read-only, and
# bootstrap-gitops.sh would install a whole GitOps control plane into it.
#
# So this refuses rather than warns, and there is NO environment override: the
# outcome it prevents is applying workshop manifests to an employer's cluster,
# and an override flag is precisely the line that gets copy-pasted past a
# safety check. Selecting the right context is one command, and it is printed.
#
# Both halves are asserted, because neither is sufficient alone:
#   * the context NAME — create-cluster.sh guarantees admin@${CLUSTER_NAME};
#     kind-fallback.sh, the documented lifeboat, guarantees kind-${CLUSTER_NAME}
#     and must keep working. A name is one `kubectl config rename-context`
#     away from being wrong, and says nothing about where it points.
#   * the API SERVER address — a workshop cluster is a container on this
#     laptop, so its API server is published on loopback. But every other local
#     cluster (minikube, k3d, Docker Desktop, a port-forwarded bastion) is on
#     loopback too, so the address alone would let those through.
#
# The guard makes no API call: it reads the kubeconfig only. A workshop cluster
# that is stopped or broken still passes it, so module 01's "kubectl cannot
# reach the cluster" diagnosis stays module 01's job.
# =============================================================================

# Guard against direct execution — this file is meant to be sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "context-guard.sh is a library; source it from another script." >&2
  exit 1
fi

# CLUSTER_NAME and TALOS_SUBNET_GATEWAY come from the single pin source; the
# guard must never be a second place where the cluster name is written down.
# Sourced here rather than assumed, so this file works whichever way it is
# reached (lab/common.sh and scripts/lib.sh both also source it — versions.env
# is pure assignments, so re-sourcing it is a no-op).
CONTEXT_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${CONTEXT_GUARD_DIR}/versions.env"

# workshop_api_server <server-url> — true for an API server address that a
# CloudBox cluster on this machine can legitimately have:
#   https://127.0.0.1:<port>  create-cluster.sh repoints the kubeconfig at the
#                             controlplane container's published port, and
#                             kind-fallback.sh publishes its API the same way.
#   https://localhost:<port>  the same address, spelled the other way.
#   https://10.5.0.2:6443     create-cluster.sh's documented fallback for when
#                             it cannot read the published port (fine on native
#                             Linux): the controlplane's own address inside
#                             TALOS_SUBNET, which is .2 — .1 is the gateway.
workshop_api_server() { # <server-url>
  case "$1" in
    https://127.0.0.1:[0-9]*|https://localhost:[0-9]*) return 0 ;;
    "https://${TALOS_SUBNET_GATEWAY%.*}.2:6443")       return 0 ;;
    *) return 1 ;;
  esac
}

# require_workshop_context — exit non-zero unless kubectl's CURRENT context is
# this workshop's cluster. Call it before the first kubectl call that could
# reach a cluster; never at source time in scripts/lib.sh (see the header).
require_workshop_context() {
  local ctx server reason
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  server=""
  if [ -n "$ctx" ]; then
    server="$(kubectl config view --minify \
      -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  fi

  if [ -z "$ctx" ]; then
    reason="kubectl has no current context selected"
  elif [ "$ctx" != "admin@${CLUSTER_NAME}" ] && [ "$ctx" != "kind-${CLUSTER_NAME}" ]; then
    reason="the current context is '${ctx}', which is not this workshop's"
  elif ! workshop_api_server "$server"; then
    reason="context '${ctx}' points at ${server:-an API server it does not name}, which is not a cluster on this machine"
  else
    return 0
  fi

  cat >&2 <<EOF
❌ FAIL: refusing to touch this cluster — ${reason}.

  current context : ${ctx:-<none>}
  API server      : ${server:-<none>}
  expected        : admin@${CLUSTER_NAME} (or kind-${CLUSTER_NAME}) on https://127.0.0.1:<port>

The workshop scripts create, patch and delete resources in whatever cluster
kubectl points at, so this stops here instead of guessing.

Point kubectl back at your workshop cluster:
  kubectl config use-context admin@${CLUSTER_NAME}
  kubectl config use-context kind-${CLUSTER_NAME}    # only if you used ./scripts/kind-fallback.sh

No such context? Then you have no cluster right now — ./scripts/destroy-cluster.sh
removes it and kubectl silently falls through to the next entry in ~/.kube/config.
Build one:
  ./scripts/create-cluster.sh
EOF
  exit 1
}
