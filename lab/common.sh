#!/usr/bin/env bash
# Shared helpers for lab solve.sh / verify.sh scripts. Source me, don't run me.
#
# The single write-path of this platform is the in-cluster Gitea repo; these
# helpers clone it, push to it, and wait for ArgoCD to converge.
#
# Sourcing this file also RUNS the workshop-context guard below. That is
# deliberate: it is the one place every module already passes through, so no
# lab script can forget it. Two scripts source it deliberately LATE, because
# they legitimately run before a cluster exists — see the comments in
# lab/01-cluster/{verify,solve}.sh.

LAB_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CLUSTER_NAME and TALOS_SUBNET_GATEWAY come from the single pin source; the
# guard must never be a second place where the cluster name is written down.
# shellcheck source=../scripts/versions.env
source "${LAB_COMMON_DIR}/../scripts/versions.env"

# =============================================================================
# Workshop-context guard — fail closed; never touch someone else's cluster.
#
# Every helper here talks to "whatever cluster kubectl currently points at".
# That is harmless on a laptop with one cluster and dangerous on the laptops
# this workshop is for, whose owners arrive with a dozen contexts. Rehearsal 3
# reproduced it on the ordinary attendee path: destroy-cluster.sh removes the
# admin@cloudbox kubeconfig entries, the current context falls through to the
# next entry in the same ~/.kube/config, and lab/01-cluster/verify.sh then
# printed "✅ kubectl reaches the API server" and "want 2 Ready nodes, have
# 36/36" — against a real 36-node corporate cluster. verify.sh is read-only, so
# nothing was harmed; solve.sh, inject.sh and restore.sh are not read-only.
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
# this workshop's cluster. Called at the bottom of this file, on every source.
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

The lab scripts create, patch and delete resources in whatever cluster kubectl
points at, so this stops here instead of guessing.

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

require_workshop_context

GITEA_HOST="${GITEA_HOST:-localhost:30300}"
GITEA_REPO_URL="${GITEA_REPO_URL:-http://gitea_admin:cloudbox123@${GITEA_HOST}/cloudbox/platform.git}"

# Clone the platform repo from in-cluster Gitea into a temp dir; prints the path.
# On failure: cleans up the temp dir and fails with a friendly pointer (callers
# run under `set -e`, so the non-zero return stops their script).
gitops_clone() {
  local dir
  dir="$(mktemp -d)"
  if ! git clone -q "$GITEA_REPO_URL" "$dir/platform" 2>/dev/null; then
    rm -rf "$dir"
    echo "ERROR: could not clone http://${GITEA_HOST}/cloudbox/platform.git —" \
      "is Gitea up and seeded? (./scripts/bootstrap-gitops.sh, then ./scripts/seed-gitea.sh)" >&2
    return 1
  fi
  echo "$dir/platform"
}

# Commit + push everything staged-able in <clone-dir> (no-op if nothing changed).
gitops_push() { # <clone-dir> <commit-message>
  git -C "$1" add -A
  if ! git -C "$1" diff --cached --quiet; then
    git -C "$1" -c user.name="cloudbox" -c user.email="cloudbox@localhost" \
      commit -q -m "$2"
    git -C "$1" push -q
  fi
}

# Copy catalog Application manifests into gitops/apps/ inside a clone.
enable_catalog() { # <clone-dir> <catalog-file.yaml>...
  local clone="$1"; shift
  local f
  for f in "$@"; do
    cp "$clone/gitops/catalog/$f" "$clone/gitops/apps/$f"
  done
}

# Ask ArgoCD to compare against git right now instead of waiting for the poll.
argocd_refresh() { # <app-name>
  kubectl -n argocd annotate application "$1" \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
}

# Block until an ArgoCD Application is Synced + Healthy (default 420s).
wait_app() { # <app-name> [timeout-seconds]
  local name="$1" timeout="${2:-420}" waited=0 st
  argocd_refresh platform
  while [ "$waited" -lt "$timeout" ]; do
    argocd_refresh "$name"
    st="$(kubectl -n argocd get application "$name" \
      -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || true)"
    # Succeed on HEALTH — the workloads are running, which is what every
    # capability check downstream actually needs. Sync status (the git-vs-cluster
    # diff) is advisory: an app legitimately sits "OutOfSync Healthy" while ArgoCD
    # is mid-reconcile or on a benign serverside-apply field diff, and timing out
    # on that is a race, not a real failure (the functional assertions that follow
    # catch genuine breakage). Requiring "Synced Healthy" was a recurring flake.
    local sync="${st%% *}" health="${st##* }"
    if [ "$health" = "Healthy" ]; then
      if [ "$sync" = "Synced" ]; then
        echo "app '$name' is Synced/Healthy"
      else
        echo "app '$name' is Healthy (sync: ${sync:-unknown})"
      fi
      return 0
    fi
    # If the child Application doesn't exist yet, the app-of-apps parent hasn't
    # rendered it — hard-refresh the parent to nudge child creation. Fixes
    # intermittent "last: missing" timeouts when ArgoCD is slow to reconcile the
    # git push under load (only fires while the child is absent).
    if [ -z "$st" ]; then
      kubectl -n argocd annotate application platform \
        argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
    fi
    # Poll every 5s (not 10s): apps usually flip Healthy between polls, so a
    # tighter cadence halves the average detection latency across the many
    # wait_app calls in a run, without touching the timeout budget.
    sleep 5
    waited=$((waited + 5))
  done
  echo "ERROR: timed out after ${timeout}s waiting for app '$name' (last: ${st:-missing})" >&2
  return 1
}

# wait_exists <ns> <kind/name> [timeout-seconds] — poll until a resource EXISTS.
# `kubectl wait --for=condition=...` errors immediately on a missing resource
# (it does not wait for creation), and wait_app now returns on app HEALTH — an
# app can be Healthy while still OutOfSync with a resource not yet applied. Use
# this before any `kubectl wait` on a resource an ArgoCD app is expected to create.
wait_exists() {
  local ns="$1" obj="$2" timeout="${3:-300}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    kubectl -n "$ns" get "$obj" >/dev/null 2>&1 && return 0
    sleep 5
    waited=$((waited + 5))
  done
  echo "ERROR: $obj never appeared in ns $ns after ${timeout}s" >&2
  return 1
}

# wait_for_cr <ns> <resource> [crd] — the demo app can report Synced while
# SKIPPING a custom resource whose CRD wasn't Established yet
# (SkipDryRunOnMissingResource), leaving the CR "not found" when a solve script
# immediately waits on it. This closes that race: optionally wait for the CRD
# Established, nudge the demo app to re-apply, then poll for the CR to appear.
# (Recurring finding across modules 03/04/06 in rehearsal-in-CI.)
wait_for_cr() {
  ns="$1"; resource="$2"; crd="${3:-}"
  if [ -n "$crd" ]; then
    # `kubectl wait` on a named object that does not exist YET fails immediately
    # with "Error from server (NotFound)" — it waits for a condition, never for
    # creation. wait_app returns on Healthy alone (see its comment), so an app can
    # legitimately still be OutOfSync with its CRDs unapplied at this point, and
    # under `set -e` that NotFound kills the whole solve script. Poll the CRD into
    # existence first, then wait on the condition.
    for _ in $(seq 1 60); do
      kubectl get "crd/$crd" >/dev/null 2>&1 && break
      sleep 5
    done
    kubectl wait --for=condition=Established "crd/$crd" --timeout=180s
  fi
  kubectl -n argocd annotate application demo argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    kubectl -n "$ns" get "$resource" >/dev/null 2>&1 && return 0
    sleep 5
  done
  echo "ERROR: $resource never appeared in ns $ns" >&2
  return 1
}
