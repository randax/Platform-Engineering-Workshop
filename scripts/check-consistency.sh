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
#   9. the workshop kubeconfig path agrees between mise.toml and
#      scripts/context-guard.sh
#  10. the tbx pin agrees between versions.env and mise.toml, and the tbx
#      cluster yaml is generated from the pins rather than checked in
#  11. the cni:none machine-config patch is byte-identical in both substrate
#      backends, so both substrates produce the same cluster
#  12. browser-facing URLs use the shared hostname scheme, not Docker-only
#      localhost NodePorts or the former sslip.io Knative domain
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
  "scripts/substrate/docker.sh"   # backend: it CREATES the workshop context, so
                                  # there is nothing to assert while it runs;
                                  # create-cluster.sh (checked, not exempt)
                                  # calls the guard the moment it returns
  "scripts/substrate/tbx.sh"      # the other backend, same reason: it is what
                                  # creates the workshop context (talosctl
                                  # kubeconfig + kubectl config use-context)
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
  # Match kubectl only where it is a COMMAND — start of line, or after a
  # pipe/semicolon/&&/subshell — so that printed advice ("point kubectl back
  # at ...") is allowed while an actual invocation is not. Both scripts now
  # tell attendees which kubeconfig they are on, which is prose about kubectl,
  # not a call to it.
  offenders="$(grep -nE '(^|[;&|(]|\$\()[[:space:]]*kubectl[[:space:]]' "${f}" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
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
# `kubectl --kubeconfig=<file> config …` counts as named-entry surgery too: the
# flag only says WHICH file to edit, and destroy-cluster.sh now cleans the
# workshop's entries out of both the pinned kubeconfig and ~/.kube/config.
offenders="$(grep -n 'kubectl' scripts/destroy-cluster.sh | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE 'kubectl (--kubeconfig="[^"]*" )?config |have kubectl' || true)"
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

# --- 9. the workshop kubeconfig path is written down in exactly two places -----
# mise.toml's `[env] KUBECONFIG` is what actually pins the file; shell cannot
# read mise's {{env.HOME}} templating, so scripts/context-guard.sh carries the
# same path as CLOUDBOX_KUBECONFIG for the guard's diagnosis, install.sh's
# report and destroy-cluster.sh's cleanup. If those two ever drift apart the
# guard would tell people to export a path nothing uses — the exact class of
# confident-wrong-answer this repo keeps finding. Two places, one truth.
before_fail=${FAILURES}
# mise templating -> shell templating, via variables rather than a backslash-
# escaped inline replacement. `${v//\{\{env.HOME\}\}/\$\{HOME\}}` is not portable:
# bash 5 eats the backslashes and yields '${HOME}', bash 3.2 keeps them and
# yields '$\{HOME\}', so the comparison below could never match and this check
# reported drift that did not exist — on macOS only, where /bin/bash IS 3.2.
# CI runs bash 5 and stayed green, so the failure looked like a real one to the
# only people who would ever run this locally. A check that cries wolf on the
# maintainer's own laptop is worse than no check.
kc_normalize() { # $1 = a mise [env] path -> the same path in shell templating
  # shellcheck disable=SC2016  # deliberate: the LITERAL text '${HOME}' is the
  # replacement, not this shell's home directory — expanding it is the bug.
  local mise_tmpl='{{env.HOME}}' shell_tmpl='${HOME}'
  printf '%s\n' "${1//${mise_tmpl}/${shell_tmpl}}"
}
# Section-aware: a KUBECONFIG line outside [env] pins nothing.
mise_kc="$(awk -F= '
  /^\[/            { in_env = ($0 ~ /^\[env\]/) ; next }
  in_env && $1 ~ /^KUBECONFIG[[:space:]]*$/ {
    v = $2; gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", v); print v; exit
  }' mise.toml)"
guard_kc="$(grep -E '^CLOUDBOX_KUBECONFIG=' scripts/context-guard.sh | head -1 | sed -E 's/^[^=]*="(.*)"$/\1/')"
if [[ -z "${mise_kc}" ]]; then
  bad "mise.toml has no [env] KUBECONFIG pin — the workshop kubeconfig would fall back to ~/.kube/config, where a destroy makes kubectl fall through to whatever else is there (docs/HAZARDS.md)"
elif [[ -z "${guard_kc}" ]]; then
  bad "scripts/context-guard.sh no longer defines CLOUDBOX_KUBECONFIG — the guard cannot tell someone their cluster is in another kubeconfig"
elif [[ "${mise_kc}" == /Users/* || "${mise_kc}" == /home/* ]]; then
  bad "mise.toml pins KUBECONFIG to a hardcoded home directory ('${mise_kc}') — this file ships to 80 laptops; use mise templating ({{env.HOME}})"
elif [[ "$(kc_normalize "${mise_kc}")" != "${guard_kc}" ]]; then
  bad "the workshop kubeconfig path has drifted: mise.toml says '${mise_kc}', scripts/context-guard.sh says '${guard_kc}'"
fi
[[ "${FAILURES}" -eq "${before_fail}" ]] \
  && ok "workshop kubeconfig path agrees in mise.toml and scripts/context-guard.sh (${guard_kc})"

# --- 10. the tbx pin agrees between versions.env and mise.toml ----------------
# Same rule as check 3, for the substrate that is not Docker. dev-setup.sh
# installs only what mise.toml lists, so a drifted pin means an attendee runs a
# tbx whose cluster-yaml schema or `tbx manifests` sections we never tested.
before_fail=${FAILURES}
tbx_mise="$(mise_pin 'ubi:randax/talos-box')"
if [[ -z "${tbx_mise}" ]]; then
  # Fallback pin form: tbx has no published mise backend yet (upstream #95/#96/
  # #101), so mise.toml may carry it as a commented pin next to the install note.
  # In this form mise installs and enforces nothing — this check only keeps
  # versions.env and the mise.toml comment line in agreement with each other;
  # it cannot assert what binary is actually on PATH. That assertion is
  # tbx_version_check() in lib.sh, called by `install.sh --check` (as a FAIL)
  # and by substrate_preflight in tbx.sh (as a die), with
  # CLOUDBOX_ALLOW_TBX_DRIFT=1 as the escape hatch.
  tbx_mise="$(sed -nE 's|^#[[:space:]]*tbx[[:space:]]*=[[:space:]]*"([^"]+)".*|\1|p' mise.toml | head -1)"
fi
if [[ -z "${tbx_mise}" ]]; then
  bad "mise.toml records no tbx pin (neither a [tools] entry nor the commented fallback) — TBX_VERSION would be the only copy and dev-setup could install anything"
elif [[ "v${tbx_mise}" != "${TBX_VERSION}" ]]; then
  bad "tbx pin drift: versions.env ${TBX_VERSION} vs mise.toml ${tbx_mise}"
fi
# The cluster yaml must stay a PROJECTION of the pins, never a second source.
if [[ -f scripts/substrate/cloudbox.tbx.yaml ]]; then
  bad "scripts/substrate/cloudbox.tbx.yaml is checked in — the tbx cluster yaml is GENERATED from versions.env into \${TBX_CLUSTER_FILE}; only the .tmpl belongs in git"
fi
for token in __TALOS_VERSION__ __CLUSTER_NAME__ __CLOUDBOX_DOMAIN__ \
             __TBX_CP_MEMORY__ __TBX_CP_CPUS__ __TBX_WORKER_MEMORY__ \
             __TBX_WORKER_CPUS__ __TBX_DISK_SIZE__; do
  grep -q -- "${token}" scripts/substrate/cloudbox.tbx.yaml.tmpl \
    || bad "scripts/substrate/cloudbox.tbx.yaml.tmpl no longer contains ${token} — a sizing value was hardcoded into the template instead of pinned in versions.env"
done
grep -qE '^[[:space:]]+cni:' scripts/substrate/cloudbox.tbx.yaml.tmpl \
  && bad "scripts/substrate/cloudbox.tbx.yaml.tmpl declares a curated 'cni:' — that hands the cluster talos-box's Cilium 1.19.6 and its own machine config; this workshop installs Cilium ${CILIUM_VERSION} itself on BOTH substrates"
[[ "${FAILURES}" -eq "${before_fail}" ]] \
  && ok "tbx pin agrees (${TBX_VERSION}) and the cluster yaml is generated from versions.env"

# --- 11. the two substrate backends carry the same machine-config patch -------
# The cni:none / proxy:disabled / node-label / local-path-mount patch is
# duplicated in both backends so each reads standalone. Duplication is fine;
# DRIFT is not — a node label that exists on one substrate and not the other
# makes lab/01 pass on one laptop and fail on the next.
before_fail=${FAILURES}
# The patch is the body of the single-quoted heredoc that starts at the
# 'cluster:' line; sed drops the closing EOF terminator awk's range included.
patch_of() { awk '/^cluster:$/,/^EOF$/' "$1" | sed '$d'; }
# Extracting nothing from both files would "agree" while asserting nothing —
# that is how a renamed heredoc marker turns this check into decoration.
if [[ -z "$(patch_of scripts/substrate/docker.sh)" || -z "$(patch_of scripts/substrate/tbx.sh)" ]]; then
  bad "check 11 found no 'cluster:' ... EOF machine-config patch in one of the substrate backends — the heredoc moved or was renamed; fix patch_of() in this script, do not delete the check"
elif ! diff -q <(patch_of scripts/substrate/docker.sh) <(patch_of scripts/substrate/tbx.sh) >/dev/null; then
  bad "the cni:none machine-config patch has drifted between scripts/substrate/docker.sh and scripts/substrate/tbx.sh — both substrates must produce the same cluster (diff them)"
fi
[[ "${FAILURES}" -eq "${before_fail}" ]] \
  && ok "both substrate backends carry the same cni:none machine-config patch"

# --- 11b. one source for the Cilium ingress values ---------------------------
# `ingressClassName: cilium` has to mean the same thing in create-cluster.sh and
# in the kind lifeboat, or "the lifeboat serves the identical labs" is false: it
# is the ingress that answers every *.${CLOUDBOX_DOMAIN} hostname the labs and
# gitops/ are written against. Here the values are not duplicated at all — both
# read cilium_ingress_values() in lib.sh — so the check is that they still do,
# and that neither has grown a private `--set ingressController.*` beside it.
before_fail=${FAILURES}
for f in scripts/create-cluster.sh scripts/kind-fallback.sh; do
  # The INVOCATION IN ITS ONE WORKING FORM, not the string and not "a line that
  # mentions it outside a comment". Both files explain the shared helper in
  # comments — at length, deliberately — so a bare `grep -q
  # cilium_ingress_values` passed on prose alone. Excluding comments was the
  # first fix and it is still too loose: `echo cilium_ingress_values nodeport`,
  # or any other line that happens to name the helper with a word after it,
  # satisfies it while the values are inlined right below.
  #
  # There is exactly one way to call this helper — it prints one flag per line
  # and bash 3.2 on macOS has no mapfile, so both callers feed a `while read`
  # loop from a process substitution. Anchor on that, with the shape argument
  # spelled out: nothing but a real call has this form.
  grep -qE '^[[:space:]]*done[[:space:]]*<[[:space:]]*<\(cilium_ingress_values[[:space:]]+("?\$\{?[A-Za-z_]|nodeport|lb)' "${f}" \
    || bad "${f} no longer CALLS cilium_ingress_values() as 'done < <(cilium_ingress_values <shape>)' — the shared ingress values are the contract the kind lifeboat and the docker substrate both meet; do not inline them (a comment, or a line that merely names the helper, is not a call)"
  grep -qE -- '--set[[:space:]]+"?ingressController\.' "${f}" \
    && bad "${f} sets ingressController.* directly — those flags belong in cilium_ingress_values() (lib.sh), which is the single source both callers read"
done
grep -q 'cilium_ingress_values()' scripts/lib.sh \
  || bad "cilium_ingress_values() is gone from scripts/lib.sh — check 11b asserts a helper that no longer exists"
[[ "${FAILURES}" -eq "${before_fail}" ]] \
  && ok "create-cluster.sh and kind-fallback.sh share one source for the Cilium ingress values"

# --- 12. no browser-facing localhost:3xxxx literals --------------------------
# The workshop serves one hostname scheme on both substrates. A leftover
# localhost:30xxx URL works on exactly one of them, so it reads as a working
# instruction and fails on half the room — the worst kind of stale text.
#
# `127.0.0.1` counts as `localhost`: it is the same host-published port, written
# the other way, and half the shell snippets people paste from prefer the
# numeric form. The sweep was blind to it, which made "no stale localhost URLs"
# a claim about spelling rather than about reachability.
#
# Allowlisted exceptions, each for a reason a rewrite would break:
#   * scripts/substrate/docker.sh — the docker backend's own port publishing.
#   * localhost:30500 — Zot's NodePort as the NODE sees it. Only node-side
#     image references, Knative's registries-skipping-tag-resolving setting,
#     portal pull-host code/tests, and comments that explain that distinction
#     may use it. With kube-proxy replacement it answers on every node on both
#     substrates, and a tbx VM cannot resolve zot.cloudbox.k8s.test.
#   * the Slidev development server in slides/README.md, not a NodePort.
#   * .github/workflows/bootstrap-test.yaml — Docker-only integration fixtures
#     deliberately exercise published NodePorts, rather than attendee URLs.
#   * serving-core.yaml historical comments — curation records, not attendee
#     instructions; changing rendered source requires re-vendoring.
before_fail=${FAILURES}
stale="$(grep -rnE '(localhost|127\.0\.0\.1):3[0-9]{4}' \
  --include='*.sh' --include='*.md' --include='*.yaml' --include='*.yml' --include='*.go' \
  lab solutions gitops scripts slides apps .devcontainer .github README.md PLAN.md 2>/dev/null \
  | grep -v '^scripts/substrate/docker.sh:' \
  | grep -Eiv 'image(Name)?:.*localhost:30500|registries-skipping-tag-resolving|fnPullHost|_test\.go:.*30500|node.*localhost:30500|^[^:]+:[0-9]+:[[:space:]]*(#|//).*localhost:30500.*(node|kubelet)' \
  | grep -v '^\.github/workflows/bootstrap-test.yaml:' \
  | grep -v '^docs/' || true)"
if [[ -n "${stale}" ]]; then
  bad "browser-facing localhost/127.0.0.1:3xxxx literals remain — they only work on the docker substrate:"
  printf '   %s\n' "${stale}" | head -30
else
  ok "no stale localhost/127.0.0.1:3xxxx literals (the hostname scheme is the only browser URL)"
fi
stale_sslip="$(grep -rn 'sslip\.io' \
  --include='*.sh' --include='*.md' --include='*.yaml' --include='*.yml' --include='*.go' \
  lab solutions gitops scripts slides apps 2>/dev/null \
  | grep -v '^scripts/check-consistency.sh:' \
  | grep -v '^gitops/components/knative-serving/serving-core.yaml:' || true)"
if [[ -n "${stale_sslip}" ]]; then
  bad "127.0.0.1.sslip.io references remain — Knative's config-domain is now ${CLOUDBOX_DOMAIN}-based:"
  printf '   %s\n' "${stale_sslip}" | head -30
else
  ok "no sslip.io references outside docs/"
fi
[[ "${FAILURES}" -eq "${before_fail}" ]] || true

# --- 12b. no bare NodePort prose in attendee-facing lab material -------------
# Browser URLs must name the shared hostname. A NodePort is only meaningful
# here when its line explicitly identifies the Docker substrate or node-side
# use, so the narrow exemptions below preserve those infrastructure notes.
before_fail=${FAILURES}
# The range is 3[01]xxx, not 30xxx: NODEPORT_KOURIER is 31080 — the port every
# app an attendee deploys is reached on, and the one most likely to be written
# down bare. A 30000-only pattern was blind to exactly the busiest NodePort in
# the workshop.
#
# The `[^0-9.]` before the colon keeps the sweep off the middle of longer
# numbers — and used to exclude the loopback-address form with them, since the
# character before that colon is a digit. Written that way it is the same
# instruction, so it gets its own branch rather than an exemption. (Check 12
# above catches the URL spelling; this one is about bare prose.)
bare_nodeport="$(grep -rnE '(^|[^0-9.]|127\.0\.0\.1):3[01][0-9]{3}([^0-9]|$)' \
  lab/*/README.md lab/*/verify.sh lab/*/solve.sh slides/pages 2>/dev/null \
  | grep -Eiv 'docker substrate|docker-only|NodePort|node[^[:alnum:]]*(pulls|side)|node.s[[:space:]]+kubelet|kubelet' || true)"
if [[ -n "${bare_nodeport}" ]]; then
  bad "bare :3[01]xxx NodePort prose remains — use the shared hostname, or explicitly label Docker-substrate/node-side use:"
  printf '   %s\n' "${bare_nodeport}" | head -30
else
  ok "no bare :3[01]xxx NodePort prose in attendee-facing lab material"
fi
[[ "${FAILURES}" -eq "${before_fail}" ]] || true

# --- 12c. no host-side localhost:${NODEPORT_*} outside the docker backend ----
# The literal-port sweep above cannot see the templated form. A host-side
# `http://localhost:${NODEPORT_GITEA}` is a docker-substrate fact: the docker
# backend publishes those ports on the laptop, tbx does not — the NodePorts
# live inside the VMs, so on tbx such a URL hangs on TCP connect. (This is what
# broke scripts/catch-up.sh, which cloned the platform repo from a port that
# only exists on half the room's machines.)
#
# Allowlisted, each because the line is docker-gated at runtime:
#   * scripts/substrate/docker.sh — the docker backend itself; every NodePort
#     it names it also publishes.
#   * scripts/bootstrap-gitops.sh's "The NodePort URLs still work" hint, printed
#     only inside `if [[ "${BOOTSTRAP_SUBSTRATE}" == "docker" ]]` (:259-263).
#     Anchored on the text, not the line number, so a NEW violation in that same
#     file is still caught.
# (.github/workflows/bootstrap-test.yaml is docker-only by construction and is
# not in the search set.)
before_fail=${FAILURES}
tmpl_nodeport="$(grep -rnE '(localhost|127\.0\.0\.1):\$\{?NODEPORT_' \
  --include='*.sh' --include='*.md' --include='*.yaml' --include='*.yml' \
  scripts lab solutions 2>/dev/null \
  | grep -v '^scripts/check-consistency.sh:' \
  | grep -v '^scripts/substrate/docker.sh:' \
  | grep -v '^scripts/bootstrap-gitops.sh:[0-9]*:.*The NodePort URLs still work' || true)"
if [[ -n "${tmpl_nodeport}" ]]; then
  bad "host-side localhost:\${NODEPORT_*} outside the docker backend — those ports are published on the host by the docker substrate only, and hang on tbx:"
  printf '   %s\n' "${tmpl_nodeport}" | head -30
else
  ok "no host-side localhost:\${NODEPORT_*} outside the docker-gated allowlist"
fi
[[ "${FAILURES}" -eq "${before_fail}" ]] || true

# --- 12d. no docker-substrate node facts as universal truth ------------------
# The docker backend's node addresses (10.5.0.x — talosctl's default subnet,
# TALOS_SUBNET) and its container names (cloudbox-controlplane-1 /
# cloudbox-worker-1) do not exist on tbx, where nodes are VMs on a vmnet DHCP
# lease in 172.30.<n>.0/24. Module 01's README used to hand the room
# `talosctl -n 10.5.0.2 …` and `docker pause cloudbox-worker-1` as THE way to do
# it, which on half the machines is a command that cannot work.
#
# A line stays legal when it names its substrate — the same rule as 12b:
# "docker substrate" / "docker-only" for a docker fact, "tbx "/"talos-box" for a
# tbx one, and a line that names both is a comparison (lab 10's host-address
# paragraph) rather than a claim. The search set is attendee-facing material
# only; scripts/substrate/docker.sh, scripts/context-guard.sh and docs/ are
# where these addresses legitimately live in full.
before_fail=${FAILURES}
docker_only_nodes="$(grep -rnE '10\.5\.0\.|cloudbox-(controlplane|worker)-1' \
  lab/*/README.md lab/*/verify.sh lab/*/solve.sh slides/pages 2>/dev/null \
  | grep -Eiv 'docker substrate|docker-only|talos-box|tbx ' || true)"
if [[ -n "${docker_only_nodes}" ]]; then
  bad "docker-substrate node facts (10.5.0.x, cloudbox-*-1 container names) in attendee-facing material without naming the substrate — on tbx the nodes are VMs with DHCP addresses and these commands cannot work:"
  printf '   %s\n' "${docker_only_nodes}" | head -30
else
  ok "no unlabelled docker-substrate node addresses/container names in lab or slides"
fi
[[ "${FAILURES}" -eq "${before_fail}" ]] || true

# --- 13. CI project fixtures obey the console's own project-name rule --------
# The console refuses a project name containing '-' (kube.ValidProjectName /
# CheckProjectName: the Knative host is "<app>-<project>" in ONE DNS label, so a
# hyphen there makes two apps able to claim one URL). The e2e workflow drives
# the console over HTTP, so a hyphenated fixture is not a lint failure — it is a
# red CI run at the very end of a 40-minute job. That is exactly how `team-e2e`
# got in. Both halves are asserted: the Go rule still forbids the hyphen, and
# every project fixture in the workflow passes it.
before_fail=${FAILURES}
proj_rule="apps/portal/internal/kube/projects.go"
if ! grep -q 'strings.Contains(name, "-")' "${proj_rule}"; then
  bad "${proj_rule} no longer refuses a hyphenated project name — this check (and the fixtures below) are keyed to that rule"
else
  bad_fixtures=""
  while IFS= read -r line; do
    val="${line#*proj=}"
    val="${val%%[[:space:]#]*}"
    [[ -n "${val}" ]] || continue
    [[ "${val}" =~ ^[a-z0-9]([a-z0-9]{0,38}[a-z0-9])?$ ]] || bad_fixtures+="${line}"$'\n'
  done < <(grep -nE '^[[:space:]]*proj=' .github/workflows/*.yaml 2>/dev/null || true)
  if [[ -n "${bad_fixtures}" ]]; then
    bad "CI project fixture rejected by the console's project-name rule (hyphen-free DNS label) — the console would refuse it and the job would fail at the create step:"
    printf '   %s\n' "${bad_fixtures}"
  else
    ok "CI project fixtures pass the console's project-name rule"
  fi
fi
[[ "${FAILURES}" -eq "${before_fail}" ]] || true

# --- 14. exactly ONE substrate decision ---------------------------------------
# scripts/substrate-decide.sh exists because this decision was copied into four
# files and the copies drifted — lab 00 had no platform gate (an Intel Mac with
# tbx installed was graded `tbx`), lab 01 and lab 06 had no `kind` arm (the
# lifeboat was graded as a Talos-in-Docker machine), and each was written as the
# same little `case "$S" in tbx|docker) ;; *) S=docker ;; esac` ladder. The
# copies are gone; this is what stops the next one, because re-adding one is
# four keystrokes and reads like local defensiveness rather than a fork of a
# shared rule.
#
# Comment lines are exempt (`^[^#]*` cannot span the `#` that opens one) — the
# three files that used to carry a ladder now DESCRIBE it in the comment that
# says why they source the shared file instead, and that sentence is the point.
before_fail=${FAILURES}
ladder_hits="$(grep -rEn '^[^#]*\bin[[:space:]]+"?tbx"?\|"?docker"?' scripts lab solutions 2>/dev/null \
  | grep -v '^scripts/substrate-decide.sh:' || true)"
if [[ -n "${ladder_hits}" ]]; then
  bad "a substrate-decision case ladder outside scripts/substrate-decide.sh — source that file and call substrate_decide_into instead (it is logging-neutral by design, so a verifier with its own ok()/fail() can source it):"
  printf '   %s\n' "${ladder_hits}"
fi
# …and the shared decision still has the entry point those callers use.
grep -q '^substrate_decide_into()' scripts/substrate-decide.sh \
  || bad "substrate_decide_into() is gone from scripts/substrate-decide.sh — check 14 forbids the copies and points at a function that no longer exists"
for f in lab/00-setup/verify.sh lab/01-cluster/verify.sh lab/01-cluster/solve.sh lab/06-serverless/verify.sh; do
  grep -q 'substrate-decide.sh' "${f}" \
    || bad "${f} no longer sources scripts/substrate-decide.sh — it is one of the four files the shared decision was extracted FROM"
done
[[ "${FAILURES}" -eq "${before_fail}" ]] \
  && ok "one substrate decision (scripts/substrate-decide.sh), sourced by every caller"

echo
if [[ "${FAILURES}" -gt 0 ]]; then
  printf '❌ %d consistency failure(s) — fix the drift before merging.\n' "${FAILURES}"
  exit 1
fi
ok "no drift detected"
