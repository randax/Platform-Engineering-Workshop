#!/usr/bin/env bash
# =============================================================================
# catch-up.sh — jump your platform to the end-state of a module
#
# Fell behind? This force-pushes the canonical state for a module to your
# in-cluster Gitea and lets ArgoCD converge (principle 11: catch-up is
# scripted state, not hope):
#
#   1. Clones your platform repo from Gitea into a temp dir
#   2. Copies solutions/module-0N/apps/* into gitops/apps/
#      (each module's dir is cumulative — it contains everything enabled
#       by the end of that module)
#   3. Commits and force-pushes to Gitea, then asks ArgoCD to refresh
#
# Usage:
#   ./scripts/catch-up.sh <module>            # e.g. ./scripts/catch-up.sh 3
#   ./scripts/catch-up.sh <module> --rebuild  # nuclear option: destroy the
#                                             # cluster, recreate, bootstrap,
#                                             # seed, then catch up
#
# Sync can't fix a broken cluster — that's what --rebuild is for
# (budget ~10 minutes with pre-pulled images).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
}

MODULE="${1:-}"
REBUILD="false"
[[ "${2:-}" == "--rebuild" ]] && REBUILD="true"

if [[ -z "${MODULE}" || "${MODULE}" == "-h" || "${MODULE}" == "--help" ]]; then
  usage
  echo "Available modules:"
  # shellcheck disable=SC2012  # module dirs have safe names; ls keeps it readable
  ls -1d "${REPO_ROOT}/solutions"/module-* 2>/dev/null | sed 's|.*/module-|   |' || echo "   (none found)"
  exit 1
fi

# Accept "3" or "03" or "module-03"
MODULE="${MODULE#module-}"
MODULE="$(printf '%02d' "$((10#${MODULE}))")"
SOLUTION_DIR="${REPO_ROOT}/solutions/module-${MODULE}"
APPS_DIR="${SOLUTION_DIR}/apps"

[[ -d "${SOLUTION_DIR}" ]] || die "No solutions/module-${MODULE} in this repo."
[[ -d "${APPS_DIR}" ]] || die "solutions/module-${MODULE} has no apps/ directory (nothing to enable)."

# --- Optional: nuke and rebuild first ------------------------------------------
if [[ "${REBUILD}" == "true" ]]; then
  step "REBUILD requested — destroying and recreating the whole platform"
  warn "This takes ~10 minutes with pre-pulled images."
  confirm "Destroy cluster '${CLUSTER_NAME}' and rebuild to module ${MODULE}?" || die "Aborted."
  "${SCRIPT_DIR}/destroy-cluster.sh"
  "${SCRIPT_DIR}/create-cluster.sh"
  "${SCRIPT_DIR}/bootstrap-gitops.sh"
  "${SCRIPT_DIR}/seed-gitea.sh"
fi

need git

# Credentials are supplied via GIT_ASKPASS (git_as_gitea_admin), not the URL.
CLONE_URL="http://localhost:${NODEPORT_GITEA}/${PLATFORM_REPO_PATH}.git"

# --- 1. Clone the attendee's platform repo from Gitea -----------------------------
step "Cloning your platform repo from Gitea"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
if ! git_as_gitea_admin clone --quiet --depth 1 --branch main "${CLONE_URL}" "${TMP_DIR}/platform"; then
  die "Could not clone from Gitea. Is the platform seeded? Run ./scripts/seed-gitea.sh first."
fi

# --- 2. Enable the module's applications --------------------------------------------
step "Enabling applications for module ${MODULE}"
mkdir -p "${TMP_DIR}/platform/gitops/apps"
enabled=()
for f in "${APPS_DIR}"/*; do
  [[ -e "${f}" ]] || continue
  cp -R "${f}" "${TMP_DIR}/platform/gitops/apps/"
  enabled+=("$(basename "${f}")")
done
[[ ${#enabled[@]} -gt 0 ]] || die "solutions/module-${MODULE}/apps is empty."

for name in "${enabled[@]}"; do
  echo "   + gitops/apps/${name}"
done

# Module-specific workloads (demo databases, XRDs, ksvcs, …) live under
# solutions/module-0N/components/ and land in gitops/components/.
if [[ -d "${SOLUTION_DIR}/components" ]]; then
  mkdir -p "${TMP_DIR}/platform/gitops/components"
  for d in "${SOLUTION_DIR}/components"/*/; do
    [[ -d "${d}" ]] || continue
    cp -R "${d}" "${TMP_DIR}/platform/gitops/components/"
    echo "   + gitops/components/$(basename "${d}")"
  done
fi

# --- 3. Commit + push -----------------------------------------------------------------
cd "${TMP_DIR}/platform"
git add gitops/apps gitops/components
if git diff --cached --quiet; then
  ok "Gitea already matches module ${MODULE} — nothing to push."
else
  git -c user.name="catch-up" -c user.email="catch-up@cloudbox.local" \
    commit --quiet -m "catch-up: enable module ${MODULE} applications"
  git_as_gitea_admin push --force --quiet origin main
  ok "Pushed module ${MODULE} state to Gitea"
fi

# --- 4. Nudge ArgoCD (it would poll within ~3 min anyway) ------------------------------
if have kubectl && kubectl get application platform -n argocd >/dev/null 2>&1; then
  kubectl annotate application platform -n argocd \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
  info "Asked ArgoCD to refresh — watch it converge: ${ARGOCD_HOST_URL}"
fi

# --- 5. Module post-steps (imperative bits GitOps can't express) -----------------------
if [[ -x "${SOLUTION_DIR}/post.sh" ]]; then
  step "Running module ${MODULE} post-steps"
  "${SOLUTION_DIR}/post.sh"
fi

echo
ok "Caught up to the end of module ${MODULE}."
echo "   Enabled: ${enabled[*]}"
