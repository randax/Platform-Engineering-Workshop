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
    echo "  --refresh-endpoint  re-read the running cluster's API address, point the"
    echo "                      kubeconfig and the talosconfig context at it, and — once"
    echo "                      both clients answer there — \${HOME}/.cloudbox/api-endpoint."
    echo "                      Creates nothing. Run it after 'tbx cluster start' or a reboot,"
    echo "                      when the VM's DHCP lease has moved."
    exit 0 ;;
  *) die "Unknown argument: ${1} (see --help)" ;;
esac

SUBSTRATE="$(substrate_resolve)"
info "Substrate: ${SUBSTRATE}"
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
# address is a vmnet DHCP lease, so `tbx cluster start` after a reboot can bring
# the control plane up on a different address than the one in the kubeconfig and
# in ${CLOUDBOX_API_ENDPOINT_FILE}. Nothing else here can repair that: the
# kubeconfig points at a dead address, and the context guard (correctly) refuses
# an address it has no record of. This re-reads `tbx status`, rewrites the
# kubeconfig cluster entry, the talosconfig context and — only once BOTH clients
# have answered at the new address — ${CLOUDBOX_API_ENDPOINT_FILE}. It does
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
  cp_ip="$(tbx_node_ip control-plane)"
  [[ -n "${cp_ip}" ]] \
    || die "Could not read the control plane's address from 'tbx status ${CLUSTER_NAME} -o json'. Is the cluster running? Start it with 'tbx cluster start ${CLUSTER_NAME}'."
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

  # Both clients have to answer at the new address BEFORE it is recorded. The
  # endpoint file is what the context guard trusts; writing an address that
  # nothing responds at converts "kubectl cannot reach the cluster" into
  # "everything says it is fine and nothing works".
  kubectl --request-timeout=10s get --raw /readyz >/dev/null 2>&1 \
    || die "The kubeconfig now points at ${endpoint}, but the API server there did not answer /readyz. ${CLOUDBOX_API_ENDPOINT_FILE} was NOT updated. Is the cluster running ('tbx status ${CLUSTER_NAME}')? Start it with 'tbx cluster start ${CLUSTER_NAME}' and re-run this."
  if has_talos_context "${CLUSTER_NAME}"; then
    talosctl --context "${CLUSTER_NAME}" version --short >/dev/null 2>&1 \
      || die "The talosconfig context '${CLUSTER_NAME}' now points at ${cp_ip}, but the Talos API there did not answer. ${CLOUDBOX_API_ENDPOINT_FILE} was NOT updated. Check 'tbx status ${CLUSTER_NAME}' and 'talosctl --context ${CLUSTER_NAME} version'."
  fi
  ok "kubectl and talosctl both answer at ${cp_ip}"

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
  # One ingress endpoint for the whole platform. `shared` means every Ingress
  # object lands on ONE Service (cilium-ingress in kube-system) instead of one
  # LoadBalancer per Ingress — which on tbx would burn a VIP per hostname and on
  # docker would need a published port per hostname. Both substrates get the
  # same values so `ingressClassName: cilium` means the same thing in both.
  --set ingressController.enabled=true
  --set ingressController.loadbalancerMode=shared
  # EVERY hostname now goes through Cilium's Envoy, and Envoy's default route
  # timeout is 15 s. The NodePorts this replaced had no proxy in the path at
  # all, so nothing in the workshop was ever timed: the 40 MiB seed-gitea push,
  # the Console's SSE agent-ask stream and ArgoCD's gRPC-web watches would all
  # start returning 504 at 15 seconds.
  #
  # Cilium leaves the route timeout UNSET when neither a backend nor a request
  # timeout is configured (operator/pkg/model/translation/envoy_virtual_host.go
  # :495-503 — it only sets MaxStreamDuration=0 there), and unset is Envoy's
  # 15 s. The operator flag below is the global default for every Ingress,
  # including the ones attendees create themselves.
  #
  # It is 24h and NOT 0: `--ingress-default-request-timeout` defaults to 0 and
  # the ingestion code skips it precisely when it is 0
  # (operator/pkg/model/ingestion/ingress.go:44-48, `if defaultRequestTimeout
  # != 0`), so setting 0 is a no-op that reads like a fix. A duration long
  # enough that nothing in a 4-hour workshop reaches it is the only value the
  # flag can express. Per-Ingress, `ingress.cilium.io/request-timeout: "0s"`
  # DOES mean "no timeout" (the annotation is parsed into a non-nil pointer,
  # ibid. :49-58, and Envoy reads timeout 0 as disabled) — our four long-lived
  # ingresses carry it. Verified against cilium v1.20.0 sources.
  --set "operator.extraArgs[0]=--ingress-default-request-timeout=24h"
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
if [[ "${SUBSTRATE}" == "tbx" ]]; then
  # Real VIP, handed out by the CiliumLoadBalancerIPPool substrate_post_cni()
  # applies below — .200 by talos-box convention, which tbx's resolver already
  # answers for every *.${CLOUDBOX_DOMAIN} name. Until that call runs the
  # Service sits in <pending>, which is the correct state for a cluster with no
  # LB-IPAM.
  cilium_values+=(--set ingressController.service.type=LoadBalancer)
else
  # No LB implementation in a docker cluster. The controlplane container
  # publishes host 80 -> this NodePort, so the hostnames work port-free there too.
  cilium_values+=(--set ingressController.service.type=NodePort)
  cilium_values+=(--set ingressController.service.insecureNodePort="${NODEPORT_INGRESS}")
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
