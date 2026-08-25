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
# Environment overrides:
#   CLOUDBOX_SUBSTRATE    force a backend
#   CLOUDBOX_MIRROR_HOST  address where node containers/VMs reach the mirror
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

REFRESH_ENDPOINT="false"
case "${1:-}" in
  --refresh-endpoint) REFRESH_ENDPOINT="true" ;;
  "") ;;
  -h|--help)
    echo "Usage: $0 [--refresh-endpoint]"
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

# The _into form: `$(substrate_resolve)` is a subshell, so the `tbx doctor` memo
# detection fills in (TBX_DOCTOR_RC, lib.sh) died with it and substrate_preflight
# below re-ran the slowest read-only probe in the repo a second time.
SUBSTRATE=""
substrate_resolve_into SUBSTRATE
info "Substrate: ${SUBSTRATE}"
# The lifeboat is not one of the two backends this script can build, and there
# is no scripts/substrate/kind.sh for `source` to find. Refuse in words rather
# than on a missing file: this machine is running kind-fallback.sh's cluster
# (that is what wrote 'kind' into ${CLOUDBOX_SUBSTRATE_FILE}), and building a
# second cluster over it would take the same ports, the same hostnames and the
# same /etc/hosts block.
if [[ "${SUBSTRATE}" == "kind" ]]; then
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
  require_workshop_context
  ok "The context guard accepts this cluster again."
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
for _ in $(seq 1 60); do
  kubectl --request-timeout=5s get nodes >/dev/null 2>&1 && break
  sleep 2
done
kubectl --request-timeout=5s get nodes >/dev/null 2>&1 \
  || die "Kubernetes API did not come up within 2 minutes"
ok "API server is answering (nodes are NotReady until Cilium arrives — expected)"

# --- 3. Cilium ------------------------------------------------------------------------
step "Installing Cilium ${CILIUM_VERSION} (CNI + kube-proxy replacement + ingress)"
# Chart is vendored into scripts/manifests/ (re-vendor from CILIUM_HELM_REPO
# when bumping) so this needs no internet at the venue — principle 2.
# Base values from the official Talos Cilium guide:
# https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium
# k8sServiceHost=localhost:7445 is KubePrism, Talos' local API server balancer.
# --server-side=false pins helm 3's client-side apply. helm 4 defaults this to
# "auto", which for a FRESH release (every workshop cluster) resolves to
# server-side apply — a behaviour change on the one path `helm template`
# cannot exercise. Nothing here needs server-side; keeping the proven path
# makes this a same-behaviour-newer-binary bump. Drop the flag once a full
# bootstrap-test has been green with it removed.
cilium_values=(
  --set ipam.mode=kubernetes
  --set kubeProxyReplacement=true
  --set k8sServiceHost=localhost
  --set k8sServicePort=7445
  --set cgroup.autoMount.enabled=false
  --set cgroup.hostRoot=/sys/fs/cgroup
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
  # L2 announcements are what make a LoadBalancer VIP answer ARP on the shared
  # L2 segment. Enabled on BOTH substrates deliberately: on docker there is no
  # LB-IPAM pool so nothing is announced, and keeping the flag identical means
  # `cilium config view` reads the same in the room whichever laptop asks.
  --set l2announcements.enabled=true
  # Cilium's own L2 docs: the announcement leases are renewed every 5s, so a
  # 40-address pool is ~8 QPS against the API server. The chart's 1.20.0
  # defaults are lower than that on some paths; raise them explicitly. Same
  # numbers talos-box uses (internal/manifests/manifests.go:41-43).
  --set k8sClientRateLimit.qps=10
  --set k8sClientRateLimit.burst=20
)
# The ingress values come from cilium_ingress_values (lib.sh) — the SINGLE
# source, shared with the kind lifeboat, because "the lifeboat serves the
# identical labs" is only true while `ingressClassName: cilium` means the same
# thing there. The argument is the service SHAPE, not the substrate name.
#
#   tbx    — a real VIP, handed out by the CiliumLoadBalancerIPPool
#            substrate_post_cni() applies below (.200 by talos-box convention,
#            which tbx's resolver already answers for every *.${CLOUDBOX_DOMAIN}
#            name). Until that call runs the Service sits in <pending>, which is
#            the correct state for a cluster with no LB-IPAM.
#   docker — no LB implementation at all. The controlplane container publishes
#            host 80 -> NODEPORT_INGRESS, so the hostnames work port-free too.
if [[ "${SUBSTRATE}" == "tbx" ]]; then
  cilium_ingress_shape="lb"
else
  cilium_ingress_shape="nodeport"
fi
while IFS= read -r cilium_flag; do
  cilium_values+=("${cilium_flag}")
done < <(cilium_ingress_values "${cilium_ingress_shape}")

if [[ "${SUBSTRATE}" == "tbx" ]]; then
  # tbx ONLY, and taken verbatim from talos-box's own curated Cilium values
  # (internal/manifests/manifests.go:137-138, `bpf: hostLegacyRouting: true`).
  # It routes pod traffic through the host stack instead of short-cutting out of
  # BPF, which is what makes the ingress VIP reachable FROM THE HOST across
  # vmnet — the whole point of the LoadBalancer above, since on this substrate
  # the attendee's browser is outside the cluster's L2 segment and reaches it
  # through the vmnet interface. Chart key verified in the vendored 1.20.0
  # values.yaml (:716) and in `helm template … --set bpf.hostLegacyRouting=true`,
  # which renders `enable-host-legacy-routing: "true"` into the ConfigMap.
  #
  # Deliberately NOT set on docker: that path is CI-proven as it stands, the
  # host reaches the ingress through a published port rather than a VIP, and the
  # flag costs the BPF fast path. See docs/HAZARDS.md — rehearsal step 3 (VIP
  # reachability from the host) is what retires the "unproven" mark on it.
  cilium_values+=(--set bpf.hostLegacyRouting=true)
fi
helm upgrade --install cilium \
  --server-side=false \
  "${SCRIPT_DIR}/manifests/cilium-${CILIUM_VERSION}.tgz" \
  --namespace kube-system \
  "${cilium_values[@]}"

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
