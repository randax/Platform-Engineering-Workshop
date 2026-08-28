#!/usr/bin/env bash
# =============================================================================
# create-cluster.sh — module 1: create the CloudBox Talos cluster
#
# Dispatcher. Resolves which SUBSTRATE this machine runs on, sources that
# backend, runs it, then does the shared post-steps (Cilium, ingress objects,
# node Ready wait) that must be identical on both.
#
#   CLOUDBOX_SUBSTRATE=tbx      real Talos VMs via talos-box (default where
#                               `tbx doctor` passes)
#   CLOUDBOX_SUBSTRATE=docker   Talos-in-Docker containers (Windows/WSL2,
#                               Codespaces, CI, and any machine tbx fails on)
#
# Unset lets substrate_resolve() in lib.sh decide; the answer is written to
# ~/.cloudbox/substrate so every later script reads the same one.
#
# Usage:
#   ./scripts/create-cluster.sh                 # everything, including Cilium
#   ./scripts/create-cluster.sh --skip-cilium   # stop after step 2: the lab-01
#                                               # path — nodes stay NotReady
#                                               # until YOU install the CNI
#   ./scripts/create-cluster.sh --post-cni      # tbx, after your Cilium install:
#                                               # LB pool + L2 policy + VIP wait,
#                                               # nothing else (no doctor, no VM)
#
# --skip-cilium exists for teaching, not convenience: lab 01 asks attendees to
# install Cilium themselves and watch NotReady become Ready. Everything
# automated (CI, catch-up.sh, solve.sh) calls this script bare and gets the
# full behavior — do not make the flag the default.
#
# Environment overrides:
#   CLOUDBOX_SUBSTRATE    force a backend
#   CLOUDBOX_MIRROR_HOST  address where node containers/VMs reach the mirror
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

REFRESH_ENDPOINT="false"
SKIP_CILIUM="false"
POST_CNI="false"
case "${1:-}" in
  --refresh-endpoint) REFRESH_ENDPOINT="true" ;;
  --skip-cilium) SKIP_CILIUM="true" ;;
  --post-cni) POST_CNI="true" ;;
  "") ;;
  -h|--help)
    echo "Usage: $0 [--skip-cilium|--post-cni|--refresh-endpoint]"
    echo "  --skip-cilium       stop after the API answers: lab 01 installs the CNI by hand"
    echo "  --post-cni          tbx only, after --skip-cilium and YOUR Cilium install: apply the"
    echo "                      LoadBalancer pool + L2 announcement policy and wait for the"
    echo "                      ingress VIP. Runs no preflight, no 'tbx doctor', starts no VM."
    echo "  (no flags)          create the CloudBox cluster"
    echo "  --refresh-endpoint  re-read the running cluster's API address, check that both"
    echo "                      clients answer there BEFORE writing anything, then point the"
    echo "                      kubeconfig and the talosconfig context at it and record"
    echo "                      \${HOME}/.cloudbox/api-endpoint. The probes retry for up to 180s"
    echo "                      (a restarted cluster answers apid long before Kubernetes);"
    echo "                      a probe that never succeeds changes nothing."
    echo "                      Creates nothing. Run it after a reboot, or after bringing the"
    echo "                      cluster back with 'tbx cluster resume' (if you suspended it)"
    echo "                      or 'tbx cluster start', when the VM's DHCP lease has moved."
    exit 0 ;;
  *) die "Unknown argument: ${1} (see --help)" ;;
esac

# FIRST, before the decision: a record that EXISTS and cannot be read is a
# refusal, not a blank slate (lib.sh, assert_identity_readable). Ahead of
# substrate_resolve_into below on purpose — that can shell out to `tbx doctor`,
# and there is no point spending seconds deciding which substrate to build on a
# machine this script is about to refuse to touch.
assert_identity_readable
# The _into form: `$(substrate_resolve)` is a subshell, so the `tbx doctor` memo
# detection fills in (TBX_DOCTOR_RC, lib.sh) died with it and substrate_preflight
# below re-ran the slowest read-only probe in the repo a second time.
# --post-cni is tbx-only and promises "no tbx doctor". Detection runs doctor
# only when there is neither a record nor an override — a state a --skip-cilium
# create leaves behind only if the record was deleted — and a FAIL there would
# resolve to docker and refuse the flag on a live tbx cluster. Pin the answer.
if [[ "${POST_CNI}" == "true" && -z "${CLOUDBOX_SUBSTRATE:-}" && -z "$(substrate_current 2>/dev/null || true)" ]]; then
  export CLOUDBOX_SUBSTRATE="tbx"
fi
SUBSTRATE=""
substrate_resolve_into SUBSTRATE
info "Substrate: ${SUBSTRATE}"
# BEFORE anything else: is the substrate we are about to act on the one this
# machine has RECORDED? CLOUDBOX_SUBSTRATE overrides the decision, and used to
# override the record too — so `CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh`
# on a machine running the kind lifeboat (or holding tbx VMs) walked straight
# past the refusal below, persisted `docker` over the real identity, and left the
# running cluster with no script able to name it. require_identity_match (lib.sh)
# dies here, before any backend is sourced and before any state is touched, with
# the two-step recipe. Silent on a clean machine — which is what CI is.
require_identity_match "${SUBSTRATE}"
# The lifeboat is not one of the two backends this script can build, and there
# is no scripts/substrate/kind.sh for `source` to find. Refuse in words rather
# than on a missing file: this machine is running kind-fallback.sh's cluster
# (that is what wrote 'kind' into ${CLOUDBOX_SUBSTRATE_FILE}), and building a
# second cluster over it would take the same ports, the same hostnames and the
# same /etc/hosts block.
if [[ "${SUBSTRATE}" == "kind" ]]; then
  # With the `kind` binary gone there is no ./scripts/kind-fallback.sh --delete to
  # send anyone to — it opens with `need kind` — so the refusal has to name the
  # hand fix, or an attendee who uninstalled kind is told to run a command that
  # cannot run and has no other way out of this state.
  if ! have kind; then
    fail "This machine records the kind lifeboat (${CLOUDBOX_SUBSTRATE_FILE}), but the 'kind' binary is gone."
    warn "./scripts/kind-fallback.sh --delete needs it, so it cannot clean up here."
    warn "Either reinstall kind (./scripts/dev-setup.sh pins it) and run that, or — if the"
    warn "lifeboat cluster is already gone — drop the record by hand:"
    warn "  rm ${CLOUDBOX_SUBSTRATE_FILE}   # then re-run this script"
    die "Refusing to create over a recorded lifeboat."
  fi
  die "this machine runs the kind lifeboat — use ./scripts/kind-fallback.sh [--delete]"
fi
if [[ "${SUBSTRATE}" == "docker" && -z "${CLOUDBOX_SUBSTRATE:-}" && -z "$(substrate_current)" ]]; then
  info "  (tbx not used: $(substrate_doctor_reason))"
fi
# Pin the answer for everything this process later calls. substrate_resolve()
# takes CLOUDBOX_SUBSTRATE first, so exporting it here makes every later resolve
# — cloudbox_host_gateway() inside substrate_create(), and any helper the
# backend shells out to — a variable read instead of another `tbx doctor` run
# against a cluster that is halfway through being created. Must come AFTER the
# "why not tbx" line above, which reads this variable to tell an explicit
# override from a detection result. substrate_persist() below still writes the
# file: the export dies with this process, the file is what the next script reads.
export CLOUDBOX_SUBSTRATE="${SUBSTRATE}"
# shellcheck source=substrate/docker.sh
source "${SCRIPT_DIR}/substrate/${SUBSTRATE}.sh"

# --refresh-endpoint: the cluster already exists and has MOVED. On tbx a node's
# address is a vmnet DHCP lease, so a `tbx cluster start|resume` after a reboot
# can bring the control plane up on a different address than the one in the kubeconfig and
# in ${CLOUDBOX_API_ENDPOINT_FILE}. Nothing else here can repair that: the
# kubeconfig points at a dead address, and the context guard (correctly) refuses
# an address it has no record of. This re-reads `tbx status`, PROVES both clients
# answer at the new address before it writes anything, then rewrites the
# kubeconfig cluster entry and the talosconfig context, re-proves them through
# those files, and only then records ${CLOUDBOX_API_ENDPOINT_FILE}. It does
# NOTHING else: no create, no helm, no /etc/hosts.
#
# What it does NOT touch: the machine config's own `cluster.controlPlane.endpoint`
# (baked at create time by `talosctl gen config`). Client-side files are what a
# moved DHCP lease breaks first and what these three lines repair; a control
# plane that has to be told its own new address is a re-create, not a refresh.
if [[ "${REFRESH_ENDPOINT}" == "true" ]]; then
  step "Refreshing this cluster's API endpoint"
  if [[ "${SUBSTRATE}" != "tbx" ]]; then
    die "--refresh-endpoint is tbx-only: on the docker substrate the API server is published on 127.0.0.1 and cannot move. If kubectl cannot reach the cluster there, the containers are stopped (docker start) or gone (./scripts/create-cluster.sh)."
  fi
  # Which verb brings this cluster back, asked of the cluster rather than
  # assumed: `start` on a SUSPENDED cluster cold-boots it and throws the saved
  # memory away, so every message below that tells an attendee to restart says
  # `resume` when that is what their cluster needs. tbx.sh is sourced above
  # (this branch is tbx-only), so the helper is defined here.
  refresh_verb="$(tbx_restart_verb)"
  # How long the pre-write probes below may wait for a booting control plane,
  # and how often they ask. Overridable for tests; nothing else sets it.
  REFRESH_PROBE_TIMEOUT="${CLOUDBOX_REFRESH_PROBE_TIMEOUT:-180}"
  REFRESH_PROBE_INTERVAL="${CLOUDBOX_REFRESH_PROBE_INTERVAL:-5}"
  cp_ip="$(tbx_node_ip control-plane)"
  [[ -n "${cp_ip}" ]] \
    || die "Could not read the control plane's address from 'tbx status ${CLUSTER_NAME} -o json'. Is the cluster running? Bring it back with 'tbx cluster ${refresh_verb} ${CLUSTER_NAME}'."
  endpoint="https://${cp_ip}:6443"
  previous="$(api_endpoint_current)"
  # The kubeconfig's CLUSTER entry, read from the context rather than assumed:
  # talosctl names it after the cluster today, but the thing that must be
  # rewritten is whatever `admin@${CLUSTER_NAME}` actually points at.
  #
  # No fallback to "${CLUSTER_NAME}" when the lookup comes up empty: an absent
  # `admin@${CLUSTER_NAME}` context means this kubeconfig is not the one this
  # cluster wrote, and `kubectl config set-cluster` CREATES the entry it is given
  # — a guessed name would silently add a cluster stanza nothing references and
  # report success. Die before touching the file instead.
  cluster_key="$(kubectl config view \
    -o jsonpath="{.contexts[?(@.name=='admin@${CLUSTER_NAME}')].context.cluster}" 2>/dev/null || true)"
  [[ -n "${cluster_key}" ]] \
    || die "No 'admin@${CLUSTER_NAME}' context in $(kubeconfig_in_use) — nothing was changed. That file is not the one this cluster's kubeconfig was merged into: check KUBECONFIG (mise.toml pins it to ${CLOUDBOX_KUBECONFIG} for this repo), or re-create with ./scripts/create-cluster.sh if the cluster was never created on this machine."

  # PROBE FIRST, with the new address passed on the command line, and only then
  # rewrite anything. The order used to be the other way round: kubeconfig and
  # talosconfig were repointed and the probes ran afterwards, so an address that
  # answers nothing (the lease moved again between `tbx status` and here; the
  # VMs are half-started) left BOTH client files pointing at it and died. The
  # attendee was then worse off than before running the repair — and the one
  # command that repairs it is this one, which they had just watched fail.
  # Nothing below the probes can be reached without a working address, so
  # failing here leaves every file exactly as it was.
  #
  # `--server` overrides only the URL; the CA and the client certs still come
  # from the context, so this is the same TLS handshake the rewritten file would
  # perform. `--kubeconfig` and `--context` are explicit because the probe must
  # ask about THIS cluster in THIS file, not about whatever context happens to
  # be selected.
  #
  # BOUNDED RETRY, not a single shot. This command's documented caller is
  # `lab/01-cluster/solve.sh`, which runs `tbx cluster start|resume` and then
  # calls it — and neither verb promises a Kubernetes API. `cluster.resume` does
  # not go through the daemon's provisioning dispatch at all (talos-box
  # internal/daemon/server.go:468 routes only create/start/up there), so it
  # returns as soon as the VMs are resumed. `cluster.start` does wait
  # (waitForStartedClusterReady, internal/daemon/nodeboot.go:154), but the
  # Kubernetes half of that wait is bounded at 90 s and gives up SILENTLY
  # (waitForKubernetesReady, ibid. :183-215) — and it probes through the
  # kubeconfig in talos-box's own state dir, which still holds the address the
  # lease just moved away from, so on exactly the morning this repair exists for
  # it can never succeed. Either way the first /readyz here can land before
  # kube-apiserver is listening, and a single-shot probe then dies on a cluster
  # that is merely still booting — telling the attendee nothing was changed and
  # sending them to re-run the one command that would have worked a minute
  # later. The die at the end of the budget is unchanged: still fail-closed,
  # still nothing written.
  refresh_probe() { # <what> <cmd...>
    local what="$1"; shift
    local deadline=$(( SECONDS + REFRESH_PROBE_TIMEOUT )) waited=0
    while :; do
      if "$@" >/dev/null 2>&1; then
        [[ "${waited}" == 1 ]] && { echo; ok "${what} answered at ${cp_ip}"; }
        return 0
      fi
      (( SECONDS >= deadline )) && { [[ "${waited}" == 1 ]] && echo; return 1; }
      if [[ "${waited}" == 0 ]]; then
        waited=1
        info "Waiting for ${what} at ${cp_ip} (up to ${REFRESH_PROBE_TIMEOUT}s — 'tbx cluster start|resume' returns before Kubernetes answers)"
      fi
      printf '.'
      sleep "${REFRESH_PROBE_INTERVAL}"
    done
  }
  refresh_probe "the Kubernetes API" \
    kubectl --kubeconfig "$(kubeconfig_in_use)" --context "admin@${CLUSTER_NAME}" \
    --server="${endpoint}" --request-timeout=10s get --raw /readyz \
    || die "Nothing answered /readyz at ${endpoint} within ${REFRESH_PROBE_TIMEOUT}s, so nothing was changed: your kubeconfig, talosconfig and ${CLOUDBOX_API_ENDPOINT_FILE} are exactly as they were. Is the cluster running ('tbx status ${CLUSTER_NAME}')? Start it with 'tbx cluster ${refresh_verb} ${CLUSTER_NAME}' and re-run this."
  if has_talos_context "${CLUSTER_NAME}"; then
    refresh_probe "the Talos API" \
      talosctl --context "${CLUSTER_NAME}" --endpoints "${cp_ip}" --nodes "${cp_ip}" \
      version --short \
      || die "The Talos API did not answer at ${cp_ip} within ${REFRESH_PROBE_TIMEOUT}s, so nothing was changed. Check 'tbx status ${CLUSTER_NAME}' — the control plane may still be booting — and re-run this."
  fi
  ok "Both clients answer at ${cp_ip} — writing the three files"

  kubectl config set-cluster "${cluster_key}" --server="${endpoint}" >/dev/null \
    || die "Could not point the kubeconfig cluster '${cluster_key}' at ${endpoint} — is $(kubeconfig_in_use) the file with your workshop cluster in it?"

  # The talosconfig context carries its OWN copy of the address: the create path
  # bakes it in with `talosctl config endpoint/node` before merging, so a moved
  # lease leaves `talosctl --context ${CLUSTER_NAME} dashboard|dmesg|health`
  # dialing the dead one long after kubectl is well again. Same file every other
  # context operation in this repo uses (talos_config_target), and --context
  # edits the NAMED context without changing which one is selected.
  talos_target="$(talos_config_target)"
  if has_talos_context "${CLUSTER_NAME}"; then
    talosctl --context "${CLUSTER_NAME}" config endpoint "${cp_ip}" \
      || die "Could not point the talosconfig context '${CLUSTER_NAME}' (${talos_target}) at ${cp_ip}"
    talosctl --context "${CLUSTER_NAME}" config node "${cp_ip}" \
      || die "Could not set the talosconfig node for context '${CLUSTER_NAME}' (${talos_target}) to ${cp_ip}"
    ok "talosconfig context '${CLUSTER_NAME}' now points at ${cp_ip} (${talos_target})"
  else
    warn "No talosconfig context '${CLUSTER_NAME}' in ${talos_target} — talosctl was not refreshed."
    warn "  kubectl is fine; 'talosctl --context ${CLUSTER_NAME} …' will not work until the cluster is re-created."
  fi

  # The same two questions again, now with NO `--server`: this is the
  # postcondition on the rewrite, not the decision to make it (the probes above
  # were that). It proves the files themselves carry the working address, which
  # is what every later command reads — and only then is the endpoint recorded,
  # because the endpoint file is what the context guard trusts.
  #
  # `--kubeconfig` and `--context` ARE pinned, for the same reason the probe
  # above pins them: the address just written went into `admin@${CLUSTER_NAME}`
  # in $(kubeconfig_in_use), and a bare `kubectl` asks whatever context happens
  # to be current instead. That is a different cluster's kubeconfig on any
  # machine where the attendee has switched context since the create — this
  # command deliberately does not select a context — so the bare form could
  # both PASS on someone else's healthy cluster and FAIL on a rewrite that
  # worked. Only --server is dropped: the address must come from the file.
  kubectl --kubeconfig "$(kubeconfig_in_use)" --context "admin@${CLUSTER_NAME}" \
    --request-timeout=10s get --raw /readyz >/dev/null 2>&1 \
    || die "The address ${endpoint} answered a moment ago, but the rewritten kubeconfig does not reach it. ${CLOUDBOX_API_ENDPOINT_FILE} was NOT updated. Check $(kubeconfig_in_use) and 'tbx status ${CLUSTER_NAME}'."
  if has_talos_context "${CLUSTER_NAME}"; then
    talosctl --context "${CLUSTER_NAME}" version --short >/dev/null 2>&1 \
      || die "The Talos API answered at ${cp_ip} a moment ago, but the rewritten talosconfig context '${CLUSTER_NAME}' does not reach it. ${CLOUDBOX_API_ENDPOINT_FILE} was NOT updated. Check '$(talos_config_target)'."
  fi
  ok "kubectl and talosctl both answer at ${cp_ip} through their own config files"

  api_endpoint_persist "${endpoint}"
  if [[ "${previous}" == "${endpoint}" ]]; then
    ok "API endpoint unchanged: ${endpoint}"
  else
    ok "API endpoint is now ${endpoint} (was ${previous:-unrecorded})"
  fi
  info "kubeconfig: $(kubeconfig_in_use)"

  # SELECT the context, then assert it. The guard asserts kubectl's CURRENT
  # context and EXITS 1 when it is not this cluster's — which, run bare here,
  # failed the repair after every one of its writes had already succeeded, on
  # the ordinary case of an attendee who had switched context since the create.
  # The three files were correct, the endpoint was recorded, and the command
  # still ended in "❌ refusing to touch this cluster" and exit 1. This is the
  # repair for a cluster that moved: leaving kubectl pointed at it is part of
  # the repair, and it is what create-cluster.sh's own create path does.
  #
  # --kubeconfig is pinned to the file everything above was written into
  # (kubeconfig_in_use resolves the mise shim's KUBECONFIG), so the selection
  # lands where the guard will look.
  if kubectl --kubeconfig "$(kubeconfig_in_use)" config use-context "admin@${CLUSTER_NAME}" >/dev/null 2>&1; then
    ok "kubectl context selected: admin@${CLUSTER_NAME}"
    require_workshop_context
    ok "The context guard accepts this cluster again."
  else
    # Nothing above is undone by this: the kubeconfig, the talosconfig and
    # ${CLOUDBOX_API_ENDPOINT_FILE} are written and proven. Only the selection
    # failed, so this warns and names the command instead of exiting 1 on a
    # repair that worked.
    warn "Could not select 'admin@${CLUSTER_NAME}' in $(kubeconfig_in_use) — the repair itself is DONE"
    warn "(kubeconfig, talosconfig and ${CLOUDBOX_API_ENDPOINT_FILE} all point at ${cp_ip})."
    warn "Point kubectl at it yourself: kubectl config use-context admin@${CLUSTER_NAME}"
  fi
  exit 0
fi

# --post-cni: lab 01's tbx ending. The attendee created with --skip-cilium and
# installed Cilium by hand; what is still missing is the CiliumLoadBalancerIPPool
# and the CiliumL2AnnouncementPolicy (substrate_post_cni) and the proof that
# cilium-ingress landed on .200 (substrate_post_ready). Lab 01 used to say
# "re-run ./scripts/create-cluster.sh, it is idempotent" — and on tbx that
# re-run dies in substrate_preflight on "cluster already exists" first, and when
# it gets past that, `tbx doctor`'s host-pressure gate can refuse an operation
# that starts no VM at all (issue #207). So this runs ONLY the two post steps:
# no doctor, no preflight, no `tbx up`. Both read the subnet from `tbx status`
# and talk to the cluster through the kubeconfig the create already wrote.
# tbx-only, like --refresh-endpoint: on docker the ingress is a NodePort and
# there are no LB objects to apply.
if [[ "${POST_CNI}" == "true" ]]; then
  if [[ "${SUBSTRATE}" != "tbx" ]]; then
    die "--post-cni is tbx-only: on the docker substrate the ingress is a NodePort (no LoadBalancer pool or L2 policy to apply). Lab 01 on docker is complete once your Cilium install finishes."
  fi
  need kubectl
  need jq
  need tbx "Both post steps read the cluster's subnet from 'tbx status'. Install talos-box again (./scripts/dev-setup.sh pins it)."
  # The guard that every kubectl-using path in this repo runs, and the one this
  # early exit would otherwise skip: it applies LB objects and waits on nodes
  # against the CURRENT context, which after a destroy or a context switch can
  # be somebody's real cluster (scripts/context-guard.sh, rehearsal 3).
  require_workshop_context
  step "Finishing lab 01 on tbx: LoadBalancer pool, L2 policy, ingress VIP"
  kubectl get --raw /readyz >/dev/null 2>&1 \
    || die "The Kubernetes API is not answering through $(kubeconfig_in_use) — is the cluster up (tbx status ${CLUSTER_NAME})? After a reboot: ./scripts/create-cluster.sh --refresh-endpoint"
  substrate_post_cni
  step "Waiting for nodes to become Ready (your Cilium rollout)"
  wait_rollout kube-system daemonset/cilium
  kubectl wait --for=condition=Ready nodes --all --timeout=300s
  substrate_post_ready
  ok "Lab 01's tbx ending is done — every *.${CLOUDBOX_DOMAIN} name now reaches the ingress"
  exit 0
fi

substrate_preflight
# Persisted BEFORE the create, not after it. destroy-cluster.sh reads this file
# to decide what to tear down and falls back to "docker" when it is absent — so
# a tbx create that dies anywhere after `tbx up` (a failed apply-config, a
# bootstrap that never converges, Ctrl-C during the maintenance-mode wait) used
# to leave running VMs behind that the documented recovery command then never
# looked for. Preflight has already established the substrate is usable and
# that no cluster of this name exists; from here on, something may exist.
# Writing it early is safe in the other direction too: the file records the
# substrate, not the existence of a cluster, and every consumer treats "no such
# cluster" as nothing to do.
substrate_persist "${SUBSTRATE}"
substrate_create
# Idempotent by construction (substrate_persist is a whole-file write of the
# same value). Kept so the happy path still ends with the answer written, even
# if a backend ever grows a reason to change it mid-create.
substrate_persist "${SUBSTRATE}"

# The API address this cluster ended up on, recorded for the context guard —
# BEFORE require_workshop_context below, which on tbx now checks against it.
# Both backends export CLOUDBOX_API_ENDPOINT; on docker the guard accepts the
# loopback shape anyway and this is just accurate, on tbx it is the difference
# between "some address in talos-box's /16" and "this machine's cluster".
api_endpoint_persist "${CLOUDBOX_API_ENDPOINT}"

# NOT guarded at the top of this script — the backend above is what creates the
# workshop context, so there is nothing to assert until now. Here it is a
# post-condition on the backend's kubeconfig work (both branches: the published
# 127.0.0.1:<port> and the native-Linux 10.5.0.2:6443 fallback are accepted),
# asserted before the Cilium helm install and every kubectl call below start
# changing a cluster.
require_workshop_context

step "Waiting for the Kubernetes API"
# --request-timeout is load-bearing: without it kubectl blocks on the OS TCP
# connect timeout (~75s on macOS) per attempt, so an unreachable API server
# turned this "2 minutes" into over an hour of apparent hang instead of a
# failure with the message below.
#
# The budget is per-substrate because the work is: a docker node has the
# control-plane images in the local mirror and on the host's own storage, while
# a tbx VM has just booted and pulls kubelet, etcd and the apiserver over the
# guest network before any of them can answer. Two minutes is right for the
# first and far too short for the second — it failed a cluster that came up
# fine ninety seconds later.
api_wait_rounds=60         # docker: 60 x 2s = 2 minutes
[[ "${SUBSTRATE}" == "tbx" ]] && api_wait_rounds=300   # tbx: 300 x 2s = 10 minutes
for _ in $(seq 1 "${api_wait_rounds}"); do
  kubectl --request-timeout=5s get nodes >/dev/null 2>&1 && break
  sleep 2
done
kubectl --request-timeout=5s get nodes >/dev/null 2>&1 \
  || die "Kubernetes API did not come up within $((api_wait_rounds * 2 / 60)) minutes"
# One successful call is not a ready API server. On a VM the apiserver answers
# while it is still settling, and the very next client — helm, which opens its
# own connection — got `TLS handshake timeout` and failed the create on a
# cluster that was fine. Ask three times in a row before believing it.
api_steady=0
for _ in $(seq 1 90); do
  if kubectl --request-timeout=5s get --raw /readyz >/dev/null 2>&1; then
    api_steady=$((api_steady + 1))
    [[ "${api_steady}" -ge 3 ]] && break
  else
    api_steady=0
  fi
  sleep 2
done
ok "API server is answering (nodes are NotReady until Cilium arrives — expected)"

# --- 3. Cilium ------------------------------------------------------------------------
if [[ "${SKIP_CILIUM}" == "true" ]]; then
  echo
  ok "Cluster '${CLUSTER_NAME}' is up — and deliberately incomplete."
  info "The nodes are NotReady and will stay that way: this cluster has no CNI."
  info "That's your job now (lab/01-cluster/README.md, task 2). When Cilium is"
  info "in, watch it happen:"
  echo "   kubectl get nodes -w"
  echo
  info "The vendored chart is at scripts/manifests/cilium-${CILIUM_VERSION}.tgz —"
  info "the exact values live in cilium_install (scripts/lib.sh) and in the lab's hints."
  if [[ "${SUBSTRATE}" == "tbx" ]]; then
    echo
    info "tbx has one more step AFTER your Cilium is in — the LoadBalancer pool and"
    info "L2 policy the ingress VIP needs. Do NOT re-run this script bare (it refuses:"
    info "the cluster exists); run the post step only:"
    echo "   ./scripts/create-cluster.sh --post-cni"
  fi
  # The hostnames have nothing to do with the CNI, and lab 01 sends every
  # attendee down THIS branch — so writing them only in the full-install path
  # below meant the documented path ended with a healthy cluster and no working
  # *.${CLOUDBOX_DOMAIN} URL, with nothing telling anyone why. Same `|| true`
  # rule as the other call site: a declined sudo must not cost you the cluster.
  if [[ "${SUBSTRATE}" == "docker" ]]; then
    echo
    write_hosts_block || {
      warn "The ${CLOUDBOX_HOSTS_FILE} block was NOT written, so every *.${CLOUDBOX_DOMAIN}"
      warn "URL will fail on a healthy cluster. Fix it any time, the cluster keeps"
      warn "running: ./scripts/install.sh --write-hosts"
    }
  fi
  exit 0
fi

# The install itself is cilium_install (lib.sh): one copy, shared with
# lab/01-cluster/solve.sh, which has to produce the same Cilium on a cluster
# that was created with --skip-cilium.
cilium_install "${SUBSTRATE}"

substrate_post_cni

# --- 4. Wait for Ready -------------------------------------------------------------------
step "Waiting for nodes to become Ready (Cilium rollout)"
wait_rollout kube-system daemonset/cilium
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide

# Ingress-VIP wait runs AFTER nodes are Ready (not folded into
# substrate_post_cni above): the L2 announcer needs a running Cilium agent,
# and waiting on the VIP before the rollout finishes would misreport a slow
# node rollout as an ingress problem.
substrate_post_ready

# docker has no resolver: the hostnames come from a marked /etc/hosts block.
# This is the one sudo prompt in the whole workshop, and it is on the create
# path only — install.sh --check verifies, never writes. On tbx the names are
# answered by talos-box's resolver and nothing is written.
#
# LAST, after the cluster is proven healthy — it used to run before the Ready
# wait, which put the one step an attendee can REFUSE in front of everything
# that has to work. A declined sudo aborted the create with a cluster that was
# already half-built, and the obvious recovery (run it again) is then refused by
# preflight, because the node containers this run created are exactly what
# preflight looks for. Nothing above needs the names: every kubectl and helm
# call goes to the API endpoint, and the hostnames are for the attendee's
# browser afterwards.
#
# `|| true`, for the same reason write_hosts_block no longer dies: a cluster
# that is up must not be thrown away over name resolution. The failure is
# printed, the recovery command is `./scripts/install.sh --write-hosts`, and the
# summary below says so.
hosts_ok="true"
if [[ "${SUBSTRATE}" == "docker" ]]; then
  write_hosts_block || hosts_ok="false"
fi

echo
ok "Cluster '${CLUSTER_NAME}' is up — you now own a cloud. ☁️"
if [[ "${hosts_ok}" != "true" ]]; then
  warn "…but the ${CLOUDBOX_HOSTS_FILE} block was NOT written (see above), so every"
  warn "*.${CLOUDBOX_DOMAIN} URL will fail on a perfectly healthy cluster."
  warn "Fix it any time — the cluster keeps running: ./scripts/install.sh --write-hosts"
fi
info "Next steps:"
echo "   ./scripts/bootstrap-gitops.sh   # module 2: Gitea + ArgoCD"
echo "   ./scripts/seed-gitea.sh         # module 2: push this repo to your cloud"
info "Useful:"
echo "   talosctl --context ${CLUSTER_NAME} dashboard   # Talos node dashboard"
echo "   ./scripts/destroy-cluster.sh                          # tear it all down"
