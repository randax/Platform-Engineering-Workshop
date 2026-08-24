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

# =============================================================================
# Which kubeconfig file is any of this happening in?
#
# mise.toml pins KUBECONFIG to CLOUDBOX_KUBECONFIG for this repo, so on an
# activated machine the workshop cluster lives in a file of its own and a
# destroy leaves nothing to fall through to. The pin is mise's, not the
# scripts': nothing here sets KUBECONFIG, because an attendee who never
# activated mise must keep working exactly as before (everything in
# ~/.kube/config), and forcing the pin from a script would split THEM instead.
#
# The value below is the one duplicate of mise.toml's `[env] KUBECONFIG` —
# shell cannot read mise's {{env.HOME}} templating. check-consistency.sh fails
# if the two ever drift apart.
CLOUDBOX_KUBECONFIG="${HOME}/.kube/cloudbox.conf"

# kubeconfig_in_use — the file the tools in this shell will actually read.
# Three cases, because there are three populations:
#   * KUBECONFIG set (mise activated, or `mise run`/`mise exec`): that file.
#     A KUBECONFIG list is legal; kubectl WRITES to the first entry, so that is
#     the one worth naming.
#   * kubectl is a mise shim: the shim applies mise's [env] to the tool it
#     execs even though this shell never saw it, so the pin is in force while
#     $KUBECONFIG is empty. (This is CI's configuration, and the same mechanism
#     as the `KUBECONFIG=... kubectl` trap in docs/HAZARDS.md.)
#   * neither: kubectl's own default.
#
# When kubectl IS a shim, ask mise rather than guessing, because the two guesses
# above are each wrong in a case that happens: a shell that exports KUBECONFIG
# (a .zshrc export, or mise activated at $HOME where the user-level [env] sets
# it) still gets the shim's value, not its own — while a shim invoked from a
# directory mise.toml does not cover gets the user-level value, not the pin.
# `mise env` answers for the current directory, which is exactly what the shim
# will apply, in ~40 ms. Untrusted config or no mise: it prints nothing and the
# two guesses below still apply.
#
# Before this, the answer was wrong wherever the two disagreed, and it is a
# reported answer: create-cluster.sh prints it, the guard prints it, and
# install.sh --check FAILED on it ("your workshop cluster is in cloudbox.conf,
# but this shell reads ~/.kube/config") on a laptop where every tool was already
# reading cloudbox.conf and all 19 Applications were Synced+Healthy.
kubeconfig_in_use() {
  local kubectl_path mise_kc
  kubectl_path="$(command -v kubectl 2>/dev/null || true)"
  if [ "${kubectl_path%/shims/kubectl}" != "${kubectl_path}" ] && command -v mise >/dev/null 2>&1; then
    mise_kc="$(mise env -s bash 2>/dev/null | sed -n 's/^export KUBECONFIG=//p' | tail -1)"
    mise_kc="${mise_kc%\"}"; mise_kc="${mise_kc#\"}"
    if [ -n "${mise_kc}" ]; then
      echo "${mise_kc%%:*}"
      return 0
    fi
  fi
  if [ -n "${KUBECONFIG:-}" ]; then
    echo "${KUBECONFIG%%:*}"
  elif [ "${kubectl_path%/shims/kubectl}" != "${kubectl_path}" ]; then
    echo "${CLOUDBOX_KUBECONFIG}"
  else
    echo "${HOME}/.kube/config"
  fi
}

# workshop_cluster_is_elsewhere — true when the workshop cluster exists in
# CLOUDBOX_KUBECONFIG but that is NOT the file this shell is reading. That is
# the one genuinely new failure mode the pin introduces: the cluster was
# created with mise in the picture (`mise run cluster:create`, or a shell that
# was activated earlier) and is now being looked for from a shell where it is
# not. Without this the guard would tell someone whose cluster is running
# perfectly well to go and create one.
workshop_cluster_is_elsewhere() {
  [ "$(kubeconfig_in_use)" != "${CLOUDBOX_KUBECONFIG}" ] \
    && [ -f "${CLOUDBOX_KUBECONFIG}" ] \
    && kubectl --kubeconfig="${CLOUDBOX_KUBECONFIG}" config get-contexts -o name 2>/dev/null \
       | grep -qxE "admin@${CLUSTER_NAME}|kind-${CLUSTER_NAME}"
}

# workshop_api_server <server-url> — true for an API server address that a
# CloudBox cluster on this machine can legitimately have:
#   https://127.0.0.1:<port>  the docker substrate: create-cluster.sh repoints
#                             the kubeconfig at the controlplane container's
#                             published port, and kind-fallback.sh does the same.
#   https://localhost:<port>  the same address, spelled the other way.
#   https://10.5.0.2:6443     the docker substrate's documented fallback for
#                             when it cannot read the published port (fine on
#                             native Linux): the controlplane's own address
#                             inside TALOS_SUBNET, which is .2 — .1 is gateway.
#   https://172.30.<n>.<h>:6443
#                             the tbx substrate: real VMs on talos-box's own
#                             per-cluster /24 (docs/SPEC.md:186 — "cluster n ->
#                             172.30.<n>.0/24", nodes in .2-.179). There is no
#                             `docker port` rewrite there: the control plane IS
#                             routable from the host, so the kubeconfig carries
#                             the node address. 172.30.0.0/16 is RFC1918 and
#                             talos-box-owned; a corporate cluster reachable at
#                             one of these would need to be on the same laptop.
workshop_api_server() { # <server-url>
  case "$1" in
    https://127.0.0.1:[0-9]*|https://localhost:[0-9]*) return 0 ;;
    "https://${TALOS_SUBNET_GATEWAY%.*}.2:6443")       return 0 ;;
  esac
  # Pattern-matched rather than globbed: bash globs cannot express "1-3 digits".
  [[ "$1" =~ ^https://172\.30\.[0-9]{1,3}\.[0-9]{1,3}:6443$ ]]
}

# require_workshop_context — exit non-zero unless kubectl's CURRENT context is
# this workshop's cluster. Call it before the first kubectl call that could
# reach a cluster; never at source time in scripts/lib.sh (see the header).
require_workshop_context() {
  local ctx server reason kubectl_err
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  server=""
  kubectl_err=""
  if [ -n "$ctx" ]; then
    server="$(kubectl config view --minify \
      -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  else
    # An empty context has two very different causes and only one of them means
    # "you have no cluster". The other is that kubectl DID NOT RUN — on a
    # mise-shimmed laptop, `git clone <gitea>/platform && cd platform` without
    # `mise trust` makes every shimmed tool hard-fail, because the clone carries
    # this repo's mise.toml and its [env] KUBECONFIG needs trust. The cluster is
    # up and healthy in that state, so sending the person to create-cluster.sh
    # below would be exactly the confident wrong answer this guard exists to
    # avoid. Repeat the call with stderr captured to tell the two apart; the
    # happy path never pays for it. kubectl's own "no context" message is not a
    # tool failure, so it is filtered back out.
    kubectl_err="$(kubectl config current-context 2>&1 >/dev/null || true)"
    case "${kubectl_err}" in *"current-context is not set"*) kubectl_err="" ;; esac
  fi

  if [ -n "$kubectl_err" ]; then
    reason="kubectl itself did not run, so nothing here can tell which cluster you are on"
  elif [ -z "$ctx" ]; then
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
  kubeconfig      : $(kubeconfig_in_use)
  expected        : admin@${CLUSTER_NAME} (or kind-${CLUSTER_NAME}) on https://127.0.0.1:<port> (docker) or https://172.30.<n>.<h>:6443 (tbx)

The workshop scripts create, patch and delete resources in whatever cluster
kubectl points at, so this stops here instead of guessing.
EOF

  # kubectl broke rather than answered. Print what it said — nothing below this
  # point can be computed (workshop_cluster_is_elsewhere runs kubectl too, and
  # would come back just as empty), and every remedy printed below assumes a
  # kubectl that works.
  if [ -n "$kubectl_err" ]; then
    printf '\nkubectl failed instead of answering:\n\n' >&2
    printf '%s\n' "${kubectl_err}" | sed 's/^/    /' >&2
    case "${kubectl_err}" in
      *"not trusted"*)
        cat >&2 <<EOF

⚠️  That is mise refusing an untrusted config — NOT a broken cluster. Your clone of
    the platform repo carries this repo's mise.toml, which pins KUBECONFIG, and a
    fresh clone is untrusted, so every mise-shimmed tool run from inside it fails.
    Do NOT rebuild anything. Trust it once, from the clone:

      mise trust

    lab/02-gitops and lab/10-day2-ops print that next to every \`git clone\`.
EOF
        ;;
    esac
    exit 1
  fi

  # The one failure the pinned kubeconfig can cause on its own: the cluster is
  # up and healthy, in ${CLOUDBOX_KUBECONFIG}, and this shell is reading a
  # different file. Telling that person to run create-cluster.sh would be a
  # confident wrong answer — they would destroy and rebuild a working cluster.
  if workshop_cluster_is_elsewhere; then
    cat >&2 <<EOF

⚠️  Your workshop cluster is NOT missing — it is in another kubeconfig:

      ${CLOUDBOX_KUBECONFIG}     <- has a ${CLUSTER_NAME} context
      $(kubeconfig_in_use)     <- what this shell is reading

    This shell never got the KUBECONFIG that mise.toml pins for this repo,
    which happens when the cluster was created through mise (\`mise run
    cluster:create\`, or a shell where mise was activated) and this shell is
    not. Do NOT rebuild. Either of these fixes it:

      export KUBECONFIG=${CLOUDBOX_KUBECONFIG}          # this shell, right now
      eval "\$(mise activate bash)"                     # every shell (zsh/fish: see mise docs)

    ./scripts/install.sh --check reports which of the two you are.
EOF
    exit 1
  fi

  cat >&2 <<EOF

Point kubectl back at your workshop cluster:
  kubectl config use-context admin@${CLUSTER_NAME}
  kubectl config use-context kind-${CLUSTER_NAME}    # only if you used ./scripts/kind-fallback.sh

No such context? Then you have no cluster right now — ./scripts/destroy-cluster.sh
removes it and kubectl falls through to whatever else is in your kubeconfig.
Build one:
  ./scripts/create-cluster.sh
EOF
  exit 1
}
