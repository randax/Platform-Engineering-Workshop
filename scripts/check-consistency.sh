#!/usr/bin/env bash
# =============================================================================
# check-consistency.sh — mechanized drift detection between the places that
# must agree with each other (principle 14: pin everything; sync by CI, not
# by memory). Run locally or in CI; exits non-zero on any drift.
#
# Checks:
#   1. solutions/module-0N/apps/*  ==  gitops/{catalog,apps}/* (byte-for-byte)
#   2. every image reference in gitops/, lab/, solutions/ YAML — and every
#      --image= ref in scripts/, lab/, solutions/ shell scripts — is covered
#      by scripts/images.txt (the offline pre-pull guarantee)
#   3. versions.env pins match mise.toml tool pins, and the control-plane images
#      pre-pulled for KUBERNETES_VERSION are the ones create-cluster.sh will ask
#      Talos for
#   4. MISE_VERSION matches the inline copy in .devcontainer/devcontainer.json
#   5. version-pinned artifacts referenced by versions.env actually exist
#      (vendored ArgoCD manifest, vendored Cilium + Gitea chart .tgz files,
#      local-path version in the gitops component)
#   6. every row in scripts/upstream.list still resolves to a real pin, so the
#      upstream-drift manifest cannot rot when a file moves
#   7. every lab/ script that uses kubectl sources lab/common.sh, so the
#      workshop-context guard fires there (and common.sh still calls it)
#   8. every scripts/ and solutions/ script that uses kubectl CALLS
#      require_workshop_context, with a short self-policing allowlist for the
#      pre-cluster ones (and lib.sh still only defines the guard, never calls it)
#
# Offline and fast — the upstream comparison itself lives in the maintainer-only
# ./scripts/check-upstream.sh, which needs internet.
#
# Usage:
#   ./scripts/check-consistency.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"

FAILURES=0
ok()   { printf '✅ %s\n' "$1"; }
bad()  { printf '❌ FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# --- 1. solutions copies must match their catalog/apps source -------------------
count=0
for f in solutions/module-*/apps/*.yaml; do
  [[ -e "${f}" ]] || continue
  base="$(basename "${f}")"
  src=""
  [[ -f "gitops/catalog/${base}" ]] && src="gitops/catalog/${base}"
  [[ -f "gitops/apps/${base}" ]] && src="gitops/apps/${base}"
  # solutions-only extras (demo.yaml, platform-api.yaml, …) have no source copy
  [[ -n "${src}" ]] || continue
  count=$((count + 1))
  cmp -s "${src}" "${f}" || bad "${f} differs from ${src} — re-copy it"
done
[[ "${FAILURES}" -eq 0 ]] && ok "solutions apps match gitops catalog (${count} copies compared)"

# --- 2. every deployed image is on the pre-pull list ---------------------------
# Known list from images.txt (strip comments, section headers, blank lines).
known="$(grep -vE '^\s*(#|\[|$)' scripts/images.txt)"

# normalize <ref>: add docker.io/ (and library/) the way containerd does.
normalize() {
  local ref="$1"
  if [[ "${ref}" != */* ]]; then
    echo "docker.io/library/${ref}"
    return
  fi
  local first="${ref%%/*}"
  if [[ "${first}" == *.* || "${first}" == *:* || "${first}" == "localhost" ]]; then
    echo "${ref}"
  else
    echo "docker.io/${ref}"
  fi
}

# Images that are SUPPOSED to be broken (module-05 fault injection) — never
# pre-pulled, never "fixed". Keep in sync with lab/05-debug-with-ai/faults/.
DELIBERATELY_BROKEN=(
  "docker.io/library/busybox:1.37.00"   # fault 01: fat-fingered tag
)

before_fail=${FAILURES}
checked=0
# image:/imageName: fields plus Knative's *-image config keys.
while IFS= read -r ref; do
  # strip whitespace and quotes
  ref="${ref//[[:space:]]/}"
  ref="${ref//\"/}"; ref="${ref//\'/}"
  # skip templated refs, in-cluster registries, and non-image values
  case "${ref}" in
    *'$'*|zot.zot.svc*|localhost:*|cloudbox-mirror*|""|*example.com*) continue ;;
  esac
  [[ "${ref}" == */* || "${ref}" == *:* ]] || continue
  checked=$((checked + 1))
  norm="$(normalize "${ref}")"
  for broken in "${DELIBERATELY_BROKEN[@]}"; do
    [[ "${norm}" == "${broken}" ]] && continue 2
  done
  grep -qxF "${norm}" <<<"${known}" \
    || bad "image ${norm} is deployed but missing from scripts/images.txt"
done < <(
  {
    grep -rhoE '[A-Za-z-]*[iI]mage(Name)?:[[:space:]]*"?[^"[:space:]]+' \
      gitops lab solutions --include='*.yaml' 2>/dev/null \
      | sed -E 's/.*[iI]mage(Name)?:[[:space:]]*//'
    grep -rhoE -- '--image=[^"'\''[:space:]]+' \
      scripts lab solutions --include='*.sh' 2>/dev/null \
      | sed -E 's/^--image=//' | grep -E '^[A-Za-z0-9]' || true
  } | sort -u)
# Sources scanned above: image:/imageName: fields in YAML plus kubectl-run
# style --image= flags in shell scripts — both must honor the pre-pull
# guarantee. The ref-shape filter drops the matches that this very script
# produces against itself (BSD grep cannot exclude one file reliably when
# --include is also given). NOTE for bash 3.2: no comments or apostrophes
# inside the process substitution — its parser cannot find the closing paren.
[[ "${FAILURES}" -eq "${before_fail}" ]] \
  && ok "all ${checked} unique deployed image refs are on the pre-pull list"

# --- 3. versions.env pins match mise.toml --------------------------------------
mise_pin() { sed -nE "s|^\"?${1}\"?[[:space:]]*=[[:space:]]*\"([^\"]+)\".*|\1|p" mise.toml | head -1; }

talos_mise="$(mise_pin 'aqua:siderolabs/talos')"
if [[ "v${talos_mise}" == "${TALOS_VERSION}" ]]; then
  ok "Talos pin: versions.env ${TALOS_VERSION} == mise.toml ${talos_mise}"
else
  bad "Talos pin drift: versions.env ${TALOS_VERSION} vs mise.toml ${talos_mise}"
fi

kubectl_mise="$(mise_pin 'kubectl')"
if [[ "${kubectl_mise}" == "${KUBERNETES_VERSION}" ]]; then
  ok "kubectl pin: versions.env ${KUBERNETES_VERSION} == mise.toml ${kubectl_mise}"
else
  bad "kubectl pin drift: versions.env ${KUBERNETES_VERSION} vs mise.toml ${kubectl_mise}"
fi

# KUBERNETES_VERSION is DERIVED from the Talos release, not independently
# choosable: create-cluster.sh passes it as --kubernetes-version, so the nodes
# pull registry.k8s.io/kube-{apiserver,controller-manager,scheduler} and
# ghcr.io/siderolabs/kubelet at exactly that tag. Raising it without re-deriving
# images.txt from `talosctl images default` makes those four refs miss the
# offline mirror — and every other check here would stay green, because the
# images do exist upstream and mise.toml can be bumped in lockstep. So assert
# the real invariant: what we ASK Talos for is what we PRE-PULL.
before_fail=${FAILURES}
for cp_repo in ghcr.io/siderolabs/kubelet \
               registry.k8s.io/kube-apiserver \
               registry.k8s.io/kube-controller-manager \
               registry.k8s.io/kube-scheduler; do
  grep -qx "${cp_repo}:v${KUBERNETES_VERSION}" scripts/images.txt \
    || bad "control-plane image ${cp_repo}:v${KUBERNETES_VERSION} is not in scripts/images.txt — KUBERNETES_VERSION was raised without re-deriving the pre-pull list from \`talosctl images default\` (bump it WITH Talos, never ahead of it)"
done
[[ "${FAILURES}" -eq "${before_fail}" ]] \
  && ok "control-plane images pre-pulled for KUBERNETES_VERSION ${KUBERNETES_VERSION}"

# Labs, solutions and CI reach for crane with an explicit `mise x crane@<ver>`
# rather than the shim. That version must equal mise.toml's crane pin: dev-setup
# installs only what mise.toml lists, so a mismatched `mise x crane@…` would try
# to download a second crane — at the venue, offline, mid-lab.
crane_mise="$(mise_pin 'crane')"
crane_refs="$(grep -rhoE 'crane@[0-9][0-9.]*' \
  --include='*.sh' --include='*.md' --include='*.yaml' --include='*.yml' \
  scripts lab solutions gitops docs .github 2>/dev/null | sort -u || true)"
bad_crane="$(grep -v "^crane@${crane_mise}$" <<<"${crane_refs}" || true)"
if [[ -z "${crane_refs}" ]]; then
  # The refs are what this check exists to police; finding none means the grep
  # broke, not that the tree is clean.
  bad "no 'crane@<ver>' reference found anywhere — the crane pin check could not run"
elif [[ -z "${bad_crane}" ]]; then
  ok "every 'mise x crane@…' matches the mise.toml crane pin (${crane_mise})"
else
  bad "crane pin drift: mise.toml has ${crane_mise} but the tree also references $(echo "${bad_crane}" | tr '\n' ' ')— dev-setup only installs the mise.toml version, so the others need a download"
fi

# --- 4. MISE_VERSION inline copy in devcontainer.json --------------------------
if grep -q "MISE_VERSION=${MISE_VERSION} " .devcontainer/devcontainer.json; then
  ok "devcontainer MISE_VERSION matches versions.env (${MISE_VERSION})"
else
  bad "devcontainer.json MISE_VERSION differs from versions.env (${MISE_VERSION})"
fi

# --- 5. pinned artifacts exist where versions.env points -----------------------
if [[ -f "scripts/manifests/argocd-install-${ARGOCD_VERSION}.yaml" ]]; then
  ok "vendored ArgoCD manifest exists for ${ARGOCD_VERSION}"
else
  bad "scripts/manifests/argocd-install-${ARGOCD_VERSION}.yaml missing (ARGOCD_VERSION drift?)"
fi

if grep -q "local-path-provisioner:${LOCAL_PATH_PROVISIONER_VERSION}" \
     gitops/components/local-path-provisioner/local-path-storage.yaml; then
  ok "gitops local-path component matches ${LOCAL_PATH_PROVISIONER_VERSION}"
else
  bad "gitops local-path component does not pin ${LOCAL_PATH_PROVISIONER_VERSION}"
fi

if [[ -f "scripts/manifests/cilium-${CILIUM_VERSION}.tgz" ]]; then
  ok "vendored Cilium chart exists for ${CILIUM_VERSION}"
else
  bad "scripts/manifests/cilium-${CILIUM_VERSION}.tgz missing — re-vendor: helm pull cilium --repo ${CILIUM_HELM_REPO} --version ${CILIUM_VERSION} -d scripts/manifests/"
fi

if [[ -f "scripts/manifests/gitea-${GITEA_CHART_VERSION}.tgz" ]]; then
  ok "vendored Gitea chart exists for ${GITEA_CHART_VERSION}"
else
  bad "scripts/manifests/gitea-${GITEA_CHART_VERSION}.tgz missing — re-vendor: helm pull gitea --repo ${GITEA_HELM_REPO} --version ${GITEA_CHART_VERSION} -d scripts/manifests/"
fi

# --- 6. every upstream.list row resolves to a current pin ----------------------
# Offline: --pins-only reads versions.env / mise.toml / images.txt / rendered
# manifests and never touches the network. Catches a rotted pin-source (file
# renamed, variable dropped, image line rewritten) long before the maintainer
# runs the network check.
before_fail=${FAILURES}
rows=0
while IFS=$'\t' read -r up_name up_pin; do
  [[ -n "${up_name}" ]] || continue
  rows=$((rows + 1))
  [[ -n "${up_pin}" ]] \
    || bad "upstream.list row '${up_name}' resolves to no pin — its pin-source moved; fix scripts/upstream.list"
done <<<"$(./scripts/check-upstream.sh --pins-only || true)"
# rows==0 means the helper itself died (missing jq, unreadable list) — without
# this the loop would simply not run and the check would pass silently.
[[ "${rows}" -gt 0 ]] \
  || bad "check-upstream.sh --pins-only produced no rows — the check could not run"
[[ "${FAILURES}" -eq "${before_fail}" ]] \
  && ok "all ${rows} upstream.list rows resolve to a current pin"

# --- 7. every lab script that talks to a cluster passes the context guard ------
# The workshop-context guard lives in lab/common.sh and fires on source: it
# refuses to continue unless kubectl's current context is admin@cloudbox (or
# kind-cloudbox) pointing at a local API server. Rehearsal 3 found the hole it
# closes — destroy-cluster.sh removed the workshop context, kubectl fell through
# to the next entry in ~/.kube/config, and lab/01-cluster/verify.sh graded a
# 36-node corporate cluster. A new lab script that uses kubectl without sourcing
# common.sh reopens that hole silently, so the coupling is checked, not
# remembered. See docs/HAZARDS.md.
before_fail=${FAILURES}
grep -qx 'require_workshop_context' lab/common.sh \
  || bad "lab/common.sh no longer CALLS require_workshop_context — the guard is defined but never fires"
# Scripts that legitimately run before any cluster (and therefore any workshop
# context) exists. Keep this list short and justified.
GUARD_EXEMPT=(
  "lab/common.sh"            # defines the guard
  "lab/00-setup/verify.sh"   # pre-flight: only checks that the kubectl BINARY
                             # exists; must work with no cluster and no kubeconfig
)
count=0
while IFS= read -r f; do
  skip=""
  for e in "${GUARD_EXEMPT[@]}"; do [[ "${f}" == "${e}" ]] && skip=1; done
  [[ -n "${skip}" ]] && continue
  count=$((count + 1))
  grep -qE '^[[:space:]]*(source|\.)[[:space:]].*common\.sh' "${f}" \
    || bad "${f} uses kubectl but never sources lab/common.sh — the workshop-context guard would not fire there"
done < <(grep -rl --include='*.sh' 'kubectl' lab | sort)
[[ "${FAILURES}" -eq "${before_fail}" ]] \
  && ok "all ${count} kubectl-using lab scripts source the context guard"

# --- 8. the same rule for scripts/ and solutions/ ------------------------------
# scripts/ had the same exposure as lab/ and arguably worse: bootstrap-gitops.sh
# installs Gitea AND ArgoCD, seed-gitea.sh force-pushes the platform repo and
# applies the root Application, catch-up.sh plus the solutions post.sh it invokes
# rewrite the whole platform. Run against the cluster kubectl fell through to,
# that installs a GitOps control plane into someone else's cluster.
#
# Here the guard CANNOT fire on source: create-cluster.sh and kind-fallback.sh
# source lib.sh and legitimately run before any workshop context exists — they
# are what create it. So the call is explicit per script, placed after each
# script's create/rebuild branch, and this check is what makes "explicit" safe.
before_fail=${FAILURES}

if ! grep -qE '^[[:space:]]*(source|\.)[[:space:]].*context-guard\.sh' scripts/lib.sh; then
  bad "scripts/lib.sh no longer sources scripts/context-guard.sh — every scripts/ guard call would be an undefined command"
fi
if ! grep -qE '^[[:space:]]*(source|\.)[[:space:]].*context-guard\.sh' lab/common.sh; then
  bad "lab/common.sh no longer sources scripts/context-guard.sh — the guard has been copied instead of shared, or lost"
fi
if grep -qE '^[[:space:]]*require_workshop_context[[:space:]]*$' scripts/lib.sh; then
  bad "scripts/lib.sh CALLS require_workshop_context at source time — create-cluster.sh sources lib.sh BEFORE any workshop context exists, so the workshop could never be started again"
fi

# Scripts that use kubectl and are deliberately NOT guarded. Keep this list
# short and justified — each entry is re-checked below, so an exemption cannot
# quietly grow into a script that talks to a cluster.
GUARD_EXEMPT_SCRIPTS=(
  "scripts/context-guard.sh"      # defines the guard
  "scripts/lib.sh"                # defines it (never calls it — asserted above)
  "scripts/check-consistency.sh"  # this file: offline, greps for the string
  "scripts/destroy-cluster.sh"    # must work when the context is ALREADY wrong
  "scripts/dev-setup.sh"          # pre-cluster: kubectl version --client only
  "scripts/install.sh"            # pre-cluster preflight: likewise
)
count=0
while IFS= read -r f; do
  skip=""
  for e in "${GUARD_EXEMPT_SCRIPTS[@]}"; do [[ "${f}" == "${e}" ]] && skip=1; done
  [[ -n "${skip}" ]] && continue
  count=$((count + 1))
  grep -qE '^[[:space:]]*require_workshop_context[[:space:]]*$' "${f}" \
    || bad "${f} uses kubectl but never calls require_workshop_context — it would happily run against whatever cluster kubectl fell through to"
done < <(grep -rl --include='*.sh' 'kubectl' scripts solutions | sort)

# The two pre-cluster preflights are exempt only for as long as they stay
# client-side. `kubectl version --client` needs no cluster and no kubeconfig,
# which is the whole reason they may run before module 01; the moment one grows
# a real API call the exemption is wrong, so assert the reason, not the name.
for f in scripts/dev-setup.sh scripts/install.sh; do
  offenders="$(grep -n 'kubectl' "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -v 'version --client' || true)"
  [[ -z "${offenders}" ]] \
    || bad "${f} is on the pre-cluster allowlist but now runs kubectl against a cluster: ${offenders//$'\n'/ | } — guard it or take it off the list"
done

# destroy-cluster.sh is exempt because nothing in it resolves through the
# current context: `talosctl cluster destroy --name` is scoped by the container
# label, and its kubectl calls are `kubectl config` edits of NAMED kubeconfig
# entries. That is also why it MUST stay unguarded — it is the script that
# causes the fall-through, so it has to work when the context is already wrong,
# and catch-up.sh --rebuild calls it first. Assert the premise.
offenders="$(grep -n 'kubectl' scripts/destroy-cluster.sh | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE 'kubectl config |have kubectl' || true)"
[[ -z "${offenders}" ]] \
  || bad "scripts/destroy-cluster.sh is unguarded on the premise that it only edits NAMED kubeconfig entries, but it now makes a cluster call: ${offenders//$'\n'/ | }"

# catch-up.sh --rebuild destroys the cluster and creates a new one. Its guard
# call must sit AFTER that branch: in front of it, the recovery command — the
# one reserved for people already in trouble — would refuse on a cluster it is
# about to rebuild anyway.
guard_ln="$(grep -nE '^[[:space:]]*require_workshop_context[[:space:]]*$' scripts/catch-up.sh | head -1 | cut -d: -f1)"
rebuild_ln="$(grep -n 'create-cluster.sh' scripts/catch-up.sh | head -1 | cut -d: -f1)"
if [[ -n "${guard_ln}" && -n "${rebuild_ln}" && "${guard_ln}" -lt "${rebuild_ln}" ]]; then
  bad "scripts/catch-up.sh calls require_workshop_context (line ${guard_ln}) BEFORE the --rebuild branch (line ${rebuild_ln}) — --rebuild would refuse to run on the very cluster it is about to replace"
fi

[[ "${FAILURES}" -eq "${before_fail}" ]] \
  && ok "all ${count} kubectl-using scripts/ + solutions/ scripts call the context guard"

echo
if [[ "${FAILURES}" -gt 0 ]]; then
  printf '❌ %d consistency failure(s) — fix the drift before merging.\n' "${FAILURES}"
  exit 1
fi
ok "no drift detected"
