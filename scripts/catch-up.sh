#!/usr/bin/env bash
# =============================================================================
# catch-up.sh — jump your platform to the end-state of a module
#
# Fell behind? This force-pushes the canonical state for a module to your
# in-cluster Gitea and lets ArgoCD converge (principle 11: catch-up is
# scripted state, not hope):
#
#   1. Clones your platform repo from Gitea into a temp dir
#   2. REPLACES gitops/apps and gitops/components with the canonical state:
#      solutions/module-0N/apps/* (each module's dir is cumulative — it
#      contains everything enabled by the end of that module), the platform
#      component manifests from this repo, and the module's solution
#      components — broken extra FILES do not survive in git. Note what that
#      does and does not mean: the root app-of-apps runs with `prune: false`
#      on purpose (gitops/README.md), so an Application an attendee added and
#      pushed keeps RUNNING in the cluster after its file is gone. Removing the
#      workload too is `kubectl -n argocd delete application <name>`.
#   3. Commits and force-pushes to Gitea, waits for ArgoCD to converge,
#      then runs the module's imperative post-steps (post.sh)
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

# --- Am I reading the canonical state, or the attendee's own drift? -------------------
# Everything below treats ${REPO_ROOT} — the checkout this script lives in — as
# canonical, and force-pushes it over the platform repo in Gitea. seed-gitea.sh
# pushes the WHOLE repository, so the Gitea clone (lab 02: `git clone …
# cloudbox/platform`, then `mise trust`) contains scripts/, solutions/ and a
# mise.toml too: `mise run catch-up 4` runs there perfectly happily, and then
# restores the attendee's own module-09 components as "canonical" while printing
# every success line. Seen on 2026-09-01: the apps came back to module 04 (they
# come from solutions/, correct in either checkout) while
# gitops/components/demo/hello-site.yaml survived, so `demo` sat Degraded on an
# image that module 07 had not built yet and the convergence wait below ran its
# full ten minutes.
#
# Positive detection only, and never on a guess: an `origin` that points at the
# platform repo is proof. No origin at all (a tarball, a devcontainer, a
# detached copy) is NOT evidence and is left alone, and neither is the `cloudbox`
# remote a workshop checkout legitimately has pointing at the same Gitea.
catchup_origin="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
case "${catchup_origin}" in
  *"gitea.${CLOUDBOX_DOMAIN}"*|*"/${PLATFORM_REPO_PATH}.git"|*"/${PLATFORM_REPO_PATH}")
    fail "This is your platform repo (the Gitea clone), not the workshop checkout."
    warn "  ${REPO_ROOT}"
    warn "  origin: ${catchup_origin}"
    echo
    warn "catch-up reads the canonical module state from the checkout it lives in and"
    warn "force-pushes it to Gitea. Run from here, 'canonical' means whatever state your"
    warn "own platform repo is already in — it would push your drift back over itself and"
    warn "report success. The clone has scripts/ and solutions/ only because seed-gitea.sh"
    warn "pushes the whole repository."
    echo
    warn "Run it from the workshop checkout instead — the one you cloned from GitHub, with"
    warn "lab/ and docs/ in it:"
    warn "  cd <your workshop checkout> && ./scripts/catch-up.sh ${MODULE}"
    die "Nothing has been changed."
    ;;
esac

# --- Optional: nuke and rebuild first ------------------------------------------
if [[ "${REBUILD}" == "true" ]]; then
  step "REBUILD requested — destroying and recreating the whole platform"
  warn "This takes ~10 minutes with pre-pulled images."
  confirm "Destroy cluster '${CLUSTER_NAME}' and rebuild to module ${MODULE}?" || die "Aborted."
  # The substrate, captured BEFORE the destroy that erases it. destroy-cluster.sh
  # removes ${CLOUDBOX_SUBSTRATE_FILE} — correctly: it is a record of a cluster
  # that no longer exists — and the create that follows then re-DETECTS. That is
  # a different question: an attendee running on docker because `tbx doctor`
  # failed at the venue would be rebuilt onto tbx by this recovery command, on
  # the substrate whose doctor is failing, with a mirror filled for the other
  # architecture. This is the ONE place the answer is knowable, so it is carried
  # across by hand.
  REBUILD_SUBSTRATE="$(substrate_current || true)"
  if [[ "${REBUILD_SUBSTRATE}" == "kind" ]]; then
    fail "This machine runs the kind lifeboat, which --rebuild cannot rebuild: destroy-cluster.sh and create-cluster.sh both refuse there."
    warn "Rebuild it with the lifeboat's own two commands, then re-run this without --rebuild:"
    warn "  ./scripts/kind-fallback.sh --delete && ./scripts/kind-fallback.sh"
    die "Aborted before destroying anything."
  fi
  "${SCRIPT_DIR}/destroy-cluster.sh"
  if [[ -n "${REBUILD_SUBSTRATE}" ]]; then
    info "Recreating on '${REBUILD_SUBSTRATE}' — the substrate this cluster was on (CLOUDBOX_SUBSTRATE=${REBUILD_SUBSTRATE})."
    CLOUDBOX_SUBSTRATE="${REBUILD_SUBSTRATE}" "${SCRIPT_DIR}/create-cluster.sh"
  else
    "${SCRIPT_DIR}/create-cluster.sh"
  fi
  "${SCRIPT_DIR}/bootstrap-gitops.sh"
  "${SCRIPT_DIR}/seed-gitea.sh"
fi

# AFTER the --rebuild branch, never before it. --rebuild destroys the cluster
# and builds a new one, so on that path there is no workshop context at the top
# of this script and guarding there would make the recovery command — the one
# reserved for people already in trouble — permanently unusable. By here, either
# create-cluster.sh has just selected admin@${CLUSTER_NAME}, or we were asked to
# converge an existing cluster and it had better be the workshop's: everything
# below force-pushes the canonical platform state and runs post.sh against it.
require_workshop_context

need git

# Credentials are supplied via GIT_ASKPASS (git_as_gitea_admin), not the URL.
#
# The HOSTNAME, not a localhost NodePort URL: NODEPORT_GITEA is published on
# the host by the docker backend only. On tbx the NodePorts live inside the VMs
# and nothing binds them on the laptop, so a localhost clone here would hang on
# TCP connect for half the room. ${GITEA_HOST_URL} is the one URL that resolves
# on both substrates (talos-box's resolver on tbx, the /etc/hosts block on
# docker) — the same URL seed-gitea.sh pushes to (scripts/seed-gitea.sh:44).
CLONE_URL="${GITEA_HOST_URL}/${PLATFORM_REPO_PATH}.git"

# --- 1. Clone the attendee's platform repo from Gitea -----------------------------
step "Cloning your platform repo from Gitea"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
if ! git_as_gitea_admin clone --quiet --depth 1 --branch main "${CLONE_URL}" "${TMP_DIR}/platform"; then
  die "Could not clone from Gitea. Is the platform seeded? Run ./scripts/seed-gitea.sh first."
fi

# --- 2. Enable the module's applications --------------------------------------------
step "Enabling applications for module ${MODULE}"
# Catch-up REPLACES gitops/apps and gitops/components with the canonical state
# (principle 11: scripted state, not hope) — a broken extra file the attendee
# pushed must not survive the catch-up. Everything removed here is restored
# from the canonical trees below.
#
# GIT state only. The root app-of-apps is `prune: false` by design, so deleting
# the file does not delete the Application: an extra app an attendee enabled is
# still Synced+Healthy afterwards, and a BACKWARD jump (10 -> 3) leaves every
# later module's apps running. Measured in the 2026-08-18 recovery pass. That is
# the right trade for a workshop — a stale sync can never wipe someone's work —
# but it means catch-up guarantees the git state, not the cluster state.
git -C "${TMP_DIR}/platform" rm -r -q --ignore-unmatch gitops/apps gitops/components

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

# Platform component manifests come back verbatim from this repo's canonical
# gitops/components tree (the same content seed-gitea.sh pushed originally).
mkdir -p "${TMP_DIR}/platform/gitops/components"
for d in "${REPO_ROOT}/gitops/components"/*/; do
  [[ -d "${d}" ]] || continue
  # NOTE: strip the trailing slash — BSD cp -R copies a dir/'s CONTENTS
  # (flattening the tree) instead of the directory itself.
  cp -R "${d%/}" "${TMP_DIR}/platform/gitops/components/"
done

# Module-specific workloads (demo databases, XRDs, ksvcs, …) live under
# solutions/module-0N/components/ and land in gitops/components/.
if [[ -d "${SOLUTION_DIR}/components" ]]; then
  for d in "${SOLUTION_DIR}/components"/*/; do
    [[ -d "${d}" ]] || continue
    cp -R "${d%/}" "${TMP_DIR}/platform/gitops/components/"
    echo "   + gitops/components/$(basename "${d}")"
  done
fi

# --- 3. Commit + push -----------------------------------------------------------------
# Everything below stays in the directory the attendee ran this from — `git -C`
# rather than `cd`, the same way lab/common.sh and module 10's inject.sh already
# do it. Do NOT reintroduce a `cd` into the clone: the clone contains this
# repo's own mise.toml (seed-gitea.sh pushes the whole repository), and since
# the [env] KUBECONFIG pin that file needs `mise trust`. A fresh clone is
# untrusted, so on a mise-activated laptop EVERY mise-shimmed tool run from
# inside it hard-errors — and does so with exit 0 and empty stdout:
#
#   $ cd <clone> && kubectl get application platform -n argocd -o jsonpath=…
#   mise ERROR Config files in <clone>/mise.toml are not trusted.
#   st=''  rc=0
#
# which is exactly what wait_app_converged reads, so it would poll an empty
# string for ten minutes and then die on a cluster that was already converged.
git -C "${TMP_DIR}/platform" add -A gitops
if git -C "${TMP_DIR}/platform" diff --cached --quiet; then
  ok "Gitea already matches module ${MODULE} — nothing to push."
else
  git -C "${TMP_DIR}/platform" \
    -c user.name="catch-up" -c user.email="catch-up@cloudbox.local" \
    commit --quiet -m "catch-up: enable module ${MODULE} applications"
  git_as_gitea_admin -C "${TMP_DIR}/platform" push --force --quiet origin main
  ok "Pushed module ${MODULE} state to Gitea"
fi

# Block until one ArgoCD Application is Synced + Healthy, or die with its last state.
wait_app_converged() { # <app-name>
  local app="$1" timeout=600 waited=0 st=""
  while (( waited < timeout )); do
    kubectl annotate application "${app}" -n argocd \
      argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
    st="$(kubectl get application "${app}" -n argocd \
      -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || true)"
    [[ "${st}" == "Synced Healthy" ]] && break
    echo "   … ${app}: ${st:-not created yet} (${waited}s / ${timeout}s)"
    sleep 10
    waited=$((waited + 10))
  done
  if [[ "${st}" == "Synced Healthy" ]]; then
    ok "${app}: Synced/Healthy"
    return 0
  fi
  fail "Application '${app}' is still '${st:-missing}' after $((timeout / 60)) minutes."
  # "Synced" means git got what it asked for, so the manifests are not the
  # question — a workload in them is. Name the pods rather than sending someone
  # to the UI to find them, and name the cause this actually had: a workload
  # from a LATER module still in gitops/components/, whose image or dependency
  # this module has not built yet (hello-site's image does not exist until
  # module 07's in-cluster build runs, so it sits ImagePullBackOff forever).
  if [[ "${st}" == Synced* ]]; then
    warn "It is Synced, so Gitea has what this module asked for — something in it will not run:"
    kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null \
      | awk 'NR==1 || NF>=5' | sed 's/^/   /' || true
    warn "A workload from a LATER module left in gitops/components/ does exactly this. Check"
    warn "what the '${app}' Application still carries:"
    warn "  kubectl -n argocd get applications.argoproj.io ${app} -o jsonpath='{range .status.resources[*]}{.kind}/{.name}{\"\\n\"}{end}'"
    warn "If it lists workloads this module does not own, catch-up read its canonical state"
    warn "from the wrong checkout — run it from your workshop checkout, not the Gitea clone."
  fi
  die "Inspect it at ${ARGOCD_HOST_URL}, then re-run this catch-up."
}

# --- 4. Nudge ArgoCD (it would poll within ~3 min anyway) ------------------------------
if have kubectl && kubectl get application platform -n argocd >/dev/null 2>&1; then
  kubectl annotate application platform -n argocd \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
  info "Asked ArgoCD to refresh — watch it converge: ${ARGOCD_HOST_URL}"

  # --- 5. Wait for convergence before the post-steps -----------------------------------
  # post.sh scripts assume a converged PLATFORM (buckets need rustfs, the
  # module-07 build needs the WorkflowTemplate synced, …), so block until every
  # platform Application enabled above is Synced + Healthy. Generous timeout:
  # first-time syncs pull manifests, boot databases and roll out operators.
  #
  # `demo` is deliberately NOT in that gate. It carries the attendee's own
  # workloads, and from module 07 on those include hello-site, whose image
  # node-side pull image (localhost:30500/hello-site:v1) does not exist until post.sh runs the
  # in-cluster build — so gating post.sh on demo's health is a deadlock: demo
  # sits ImagePullBackOff → Degraded, the gate dies at 10 minutes, and post.sh,
  # the thing that would have fixed it, never runs. Wait for demo AFTER the
  # post-steps instead.
  step "Waiting for module ${MODULE} platform applications to converge (Synced + Healthy)"
  for name in "${enabled[@]}"; do
    app="${name%.yaml}"
    [[ "${app}" == "demo" ]] && continue
    wait_app_converged "${app}"
  done
fi

# --- 6. Module post-steps (imperative bits GitOps can't express) -----------------------
if [[ -x "${SOLUTION_DIR}/post.sh" ]]; then
  step "Running module ${MODULE} post-steps"
  "${SOLUTION_DIR}/post.sh"
fi

# --- 7. Now the attendee workloads, which the post-steps just made possible -----------
if have kubectl && printf '%s\n' "${enabled[@]}" | grep -qx 'demo.yaml' \
   && kubectl get application demo -n argocd >/dev/null 2>&1; then
  step "Waiting for the demo workloads to converge (Synced + Healthy)"
  wait_app_converged demo
fi

echo
ok "Caught up to the end of module ${MODULE}."
echo "   Enabled: ${enabled[*]}"
