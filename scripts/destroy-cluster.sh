#!/usr/bin/env bash
# =============================================================================
# destroy-cluster.sh — tear down the CloudBox Talos cluster
#
# Destroys the cluster (VMs on tbx, containers on docker) and removes its
# kubeconfig and talosconfig entries. On the docker substrate it also removes
# the marked /etc/hosts block create-cluster.sh wrote — asks for sudo once,
# because names that still point at 127.0.0.1 after the cluster is gone break
# the NEXT cluster, especially one created on the other substrate.
# The cloudbox-mirror image registry is left running (it is expensive to
# refill) unless you pass --purge-mirror.
#
# Usage:
#   ./scripts/destroy-cluster.sh                 # destroy the cluster
#   ./scripts/destroy-cluster.sh --purge-mirror  # also remove the mirror container + volume
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

PURGE_MIRROR="false"
[[ "${1:-}" == "--purge-mirror" ]] && PURGE_MIRROR="true"

need talosctl

# DELIBERATELY NOT guarded — the one script in scripts/ that must keep working
# when kubectl points at the wrong cluster, because that is the state it exists
# to clean up (and, per docs/HAZARDS.md, the state it CAUSES: removing the
# workshop kubeconfig entries is what makes kubectl fall through to the next
# ~/.kube/config entry). Guarding it would also break `catch-up.sh --rebuild`,
# whose first act is to destroy.
#
# Safe to leave unguarded because nothing here is resolved through the current
# context: `talosctl cluster destroy --name` only touches docker containers
# labelled talos.cluster.name=${CLUSTER_NAME}, and the kubectl calls below are
# `kubectl config` edits of NAMED entries (admin@${CLUSTER_NAME} and friends) —
# local kubeconfig surgery, not API calls. This script cannot delete a foreign
# cluster's resources; the CI recovery-path job asserts exactly that by proving
# an unrelated context survives a destroy.

# The substrate the cluster was CREATED on, not the one this machine would
# detect today: a laptop that has lost `tbx doctor` since the create must still
# be told to destroy VMs, not to look for docker containers that never existed.
#
# Deliberately NOT substrate_resolve(): its third step is DETECTION, and
# detection is wrong for a destroy. With no persisted answer, detection on a
# healthy tbx laptop returns "tbx" and this script would then look for VMs — and
# find none, while the docker containers a pre-substrate-split create left behind
# (or a create that died before it could persist anything) survive the "nothing
# to destroy" it prints. Detection also SHELLS OUT to `tbx doctor`, which a
# teardown has no business doing. So: the env override still wins, then the
# persisted answer, and the floor is docker — the substrate whose leftovers are
# the ones that can exist without a persisted answer.
if [[ -n "${CLOUDBOX_SUBSTRATE:-}" ]]; then
  # Assigned, never compared inline: substrate_resolve() validates the override
  # and die()s on a bad value, and only an ASSIGNMENT propagates that exit
  # status out of the command substitution for `set -e` to act on (lib.sh).
  SUBSTRATE="$(substrate_resolve)"
  info "Substrate: ${SUBSTRATE} (from CLOUDBOX_SUBSTRATE)"
else
  SUBSTRATE="$(substrate_current || true)"
  if [[ -n "${SUBSTRATE}" ]]; then
    info "Substrate: ${SUBSTRATE} (from ${CLOUDBOX_SUBSTRATE_FILE})"
  else
    SUBSTRATE="docker"
    warn "No substrate recorded in ${CLOUDBOX_SUBSTRATE_FILE} — assuming docker rather than"
    warn "detecting one, so any leftover Talos-in-Docker containers actually get destroyed."
    warn "If this machine ran the cluster on tbx: CLOUDBOX_SUBSTRATE=tbx $0 ${1:-}"
  fi
fi
# `need docker` only where the backend actually needs it — a tbx machine has no
# reason to have the docker CLI. Written as an `if` for readability, not because
# `[[ … ]] && need docker` would trip `set -e`: it would not. In an AND-list only
# the LAST command's status is examined, so a false `[[ … ]]` is ignored — the
# real trap with that form is a list as the last statement of a script or
# function, whose non-zero status then becomes the exit status.
if [[ "${SUBSTRATE}" == "docker" ]]; then
  need docker
fi
# shellcheck source=substrate/docker.sh
source "${SCRIPT_DIR}/substrate/${SUBSTRATE}.sh"
substrate_destroy
# Reached ONLY after a successful destroy or a proven absence: both backends now
# die rather than return when they cannot tell those two apart from "cannot
# look" (a stopped Docker daemon, a tbxd that will not answer). Forgetting which
# substrate a still-running cluster belongs to is unrecoverable from a script —
# every later destroy would look for the wrong kind of thing.
rm -f "${CLOUDBOX_SUBSTRATE_FILE}"

# --- Clean up kubeconfig / talosconfig contexts (best effort) -----------------
# Cleaned in EVERY file the workshop could have written to, not just the one in
# effect right now. mise.toml pins KUBECONFIG to ~/.kube/cloudbox.conf for this
# repo, but two things put ${CLUSTER_NAME} entries in ~/.kube/config anyway:
# an attendee who never activated mise (the pin never reached them), and anyone
# who created a cluster before the pin existed. A left-behind admin@${CLUSTER_NAME}
# in ~/.kube/config is exactly the entry the context guard is built to accept,
# so leaving it there would re-arm the fall-through the pin exists to disarm.
#
# ${CLOUDBOX_KUBECONFIG} is listed EXPLICITLY rather than left to
# kubeconfig_in_use(), which returns $KUBECONFIG whenever that is set and only
# falls through to the pinned file when it is not. That is one case short: a
# mise SHIM overrides an inherited KUBECONFIG (the same precedence docs/HAZARDS.md
# records as "a KUBECONFIG= prefix does nothing to a mise-shimmed kubectl"), so a
# shell that exports KUBECONFIG=~/.kube/config — a .zshrc export, or mise
# activated at $HOME where the user-level [env] sets it — creates the cluster in
# cloudbox.conf and would have cleaned ~/.kube/config. The stale admin@cloudbox
# left behind is on 127.0.0.1:<port>, i.e. precisely what the context guard
# accepts, so every later module diagnoses "you have no cluster" as "you forgot
# to push". Nonexistent files are skipped below, so this is a no-op for anyone
# who never had a pinned kubeconfig.
#
# Still only NAMED-entry surgery — no cluster is contacted, nothing that is not
# this workshop's own context/cluster/user is touched — which is the premise
# check-consistency.sh check 8 asserts to keep this script unguarded.
if have kubectl; then
  cleaned=()
  for kc in "$(kubeconfig_in_use)" "${CLOUDBOX_KUBECONFIG}" "${HOME}/.kube/config"; do
    [[ -f "${kc}" ]] || continue
    # Same path twice (the usual non-mise case) — clean it once.
    for seen in "${cleaned[@]+"${cleaned[@]}"}"; do [[ "${seen}" == "${kc}" ]] && continue 2; done
    kubectl --kubeconfig="${kc}" config delete-context "admin@${CLUSTER_NAME}" >/dev/null 2>&1 || true
    kubectl --kubeconfig="${kc}" config delete-cluster "${CLUSTER_NAME}" >/dev/null 2>&1 || true
    kubectl --kubeconfig="${kc}" config delete-user "admin@${CLUSTER_NAME}" >/dev/null 2>&1 || true
    cleaned+=("${kc}")
  done
  # `${cleaned[*]}` on an EMPTY array is an unbound-variable error under
  # `set -u` in bash 3.2 — which is /bin/bash on every Mac. The array is empty
  # when none of the three files exists, i.e. on a machine whose create died
  # before it ever merged a kubeconfig. That is precisely the state this script
  # is now the documented recovery for (create-cluster.sh persists the substrate
  # before creating anything, so a half-finished create is destroyable), so the
  # narrow case became a reachable one. Report nothing rather than crash.
  if [[ "${#cleaned[@]}" -gt 0 ]]; then
    ok "kubeconfig entries removed (${cleaned[*]})"
  else
    info "No kubeconfig held a '${CLUSTER_NAME}' entry — nothing to clean"
  fi
fi
# create-cluster.sh always leaves '${CLUSTER_NAME}' selected, and `talosctl
# config remove` SKIPS the SELECTED context while still exiting 0 — so the bare
# call here silently removed nothing, undetectably. The next create-cluster.sh
# then found the name taken, `talosctl cluster create` renamed the NEW context
# to '${CLUSTER_NAME}-1', and every `talosctl --context ${CLUSTER_NAME}` in
# create-cluster.sh talked to the cluster that had just been destroyed:
#   error copying: rpc error: ... dial tcp 127.0.0.1:53556: connect: connection refused
# i.e. destroy + create (and `catch-up.sh --rebuild`) failed on the second
# cluster of the day. remove_talos_context() in lib.sh switches away first; the
# pipe-free matchers it is built on are documented there (they are shared with
# both create backends now).
remove_talos_context "${CLUSTER_NAME}"
if has_talos_context "${CLUSTER_NAME}"; then
  warn "talosconfig still has a '${CLUSTER_NAME}' context — remove it before recreating:"
  warn "  talosctl config context <other> && talosctl config remove ${CLUSTER_NAME}"
else
  ok "talosconfig context removed"
fi

# --- /etc/hosts -------------------------------------------------------------
# Removed on EVERY docker destroy, not only under --purge-mirror. The block
# points nine hostnames at 127.0.0.1, and once the docker cluster is gone
# nothing answers there — but the names keep resolving. The failure that
# earned this: destroy the docker cluster, create the next one on tbx, and
# every *.${CLOUDBOX_DOMAIN} name still resolves to 127.0.0.1 instead of the
# cluster's ingress VIP, because /etc/hosts wins over talos-box's resolver.
# Every URL in the workshop then hangs or 404s on a cluster that is perfectly
# healthy, and nothing in the room points at /etc/hosts.
#
# Symmetric with the create: create-cluster.sh writes it on docker, this
# removes it on docker. One sudo prompt each way, and the mirror flag has
# nothing to do with hostname resolution — coupling them was the bug.
# Exactly reversible: only the lines between the two markers go, and the file
# is left byte-identical to what it was before create-cluster.sh wrote them —
# for a newline-terminated file, which /etc/hosts is on every platform we
# support. The rewrite is an awk pipeline, and awk's `print` terminates the last
# line it emits: a file that did NOT end in a newline comes back with one. That
# is the only difference the round trip can produce, and it is invisible to
# every consumer of the file.
# A no-op on tbx (nothing was ever written) and when the block is absent.
#
# `|| hosts_left=true`, and remove_hosts_block never dies: everything below this
# line — the extras file, the 7 GB mirror purge, the summary that tells the
# attendee what state their machine is in — used to be skipped when the sudo
# password was declined (or the block's markers were unpaired). The one part of
# a teardown an attendee can refuse was running before all the parts they
# cannot, which is the same ordering bug create-cluster.sh had.
hosts_left="false"
if [[ "${SUBSTRATE}" == "docker" ]]; then
  remove_hosts_block || hosts_left="true"
fi
# The attendee's own extra Knative names (install.sh --add-hosts) are a
# PREFERENCE, not cluster state: the block is gone either way, and someone who
# rebuilds the same cluster to keep working on `my-app` should not have to
# re-add it. So they survive an ordinary destroy and are cleared only by the
# same flag that throws away the 7 GB mirror — the "start over completely" one.
if [[ "${PURGE_MIRROR}" == "true" && -f "${CLOUDBOX_EXTRA_HOSTS_FILE}" ]]; then
  rm -f "${CLOUDBOX_EXTRA_HOSTS_FILE}"
  ok "Extra hostnames forgotten (${CLOUDBOX_EXTRA_HOSTS_FILE})"
fi

# --- Mirror ---------------------------------------------------------------------
if [[ "${PURGE_MIRROR}" == "true" ]]; then
  step "Purging the image mirror"
  # The mirror is a DOCKER container on both substrates, and this script only
  # requires the docker CLI on the docker path — so on a tbx machine without it
  # the two removals below are no-ops. Saying "removed" there would be a lie of
  # exactly the shape docs/HAZARDS.md calls out ("recovery tooling that lies"):
  # the attendee would believe the 7 GB mirror was gone and it would still be
  # there, serving stale images to the next cluster.
  if have docker; then
    docker rm -f "${MIRROR_NAME}" >/dev/null 2>&1 || true
    docker volume rm "${MIRROR_VOLUME}" >/dev/null 2>&1 || true
    ok "Mirror container and volume removed (re-run ./scripts/cloudbox-init.sh to refill)"
  else
    warn "docker CLI not found — the image mirror (container ${MIRROR_NAME}, volume"
    warn "${MIRROR_VOLUME}) could NOT be purged from here. It is a Docker object on both"
    warn "substrates; remove it wherever Docker actually runs, or re-run this with docker"
    warn "on PATH."
  fi
else
  info "Image mirror kept (pass --purge-mirror to remove it)"
fi

echo
if [[ "${hosts_left}" == "true" ]]; then
  warn "One thing is left on this machine: the CloudBox lines in ${CLOUDBOX_HOSTS_FILE} (see above)."
  warn "They resolve names to 127.0.0.1 where nothing listens now, and on the tbx substrate"
  warn "they would OVERRIDE talos-box's resolver on a healthy cluster. Remove them with:"
  warn "  sudo \$EDITOR ${CLOUDBOX_HOSTS_FILE}          # delete the marked block"
  warn "A later ./scripts/create-cluster.sh on docker rewrites the block and is unaffected."
fi
ok "Done. Recreate with: ./scripts/create-cluster.sh"
