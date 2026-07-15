#!/usr/bin/env bash
# Shared helpers for lab solve.sh scripts. Source me, don't run me.
#
# The single write-path of this platform is the in-cluster Gitea repo; these
# helpers clone it, push to it, and wait for ArgoCD to converge.

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
    if [ "$st" = "Synced Healthy" ]; then
      echo "app '$name' is Synced/Healthy"
      return 0
    fi
    sleep 10
    waited=$((waited + 10))
  done
  echo "ERROR: timed out after ${timeout}s waiting for app '$name' (last: ${st:-missing})" >&2
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
  [ -n "$crd" ] && kubectl wait --for=condition=Established "crd/$crd" --timeout=180s
  kubectl -n argocd annotate application demo argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    kubectl -n "$ns" get "$resource" >/dev/null 2>&1 && return 0
    sleep 5
  done
  echo "ERROR: $resource never appeared in ns $ns" >&2
  return 1
}
