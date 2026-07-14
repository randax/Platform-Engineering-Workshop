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
#   3. versions.env pins match mise.toml tool pins
#   4. MISE_VERSION matches the inline copy in .devcontainer/devcontainer.json
#   5. version-pinned artifacts referenced by versions.env actually exist
#      (vendored ArgoCD manifest, vendored Cilium + Gitea chart .tgz files,
#      local-path version in the gitops component)
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

echo
if [[ "${FAILURES}" -gt 0 ]]; then
  printf '❌ %d consistency failure(s) — fix the drift before merging.\n' "${FAILURES}"
  exit 1
fi
ok "no drift detected"
