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

# docker has no resolver: the hostnames come from a marked /etc/hosts block.
# This is the one sudo prompt in the whole workshop, and it is on the create
# path only — install.sh --check verifies, never writes. On tbx the names are
# answered by talos-box's resolver and nothing is written.
[[ "${SUBSTRATE}" == "docker" ]] && write_hosts_block

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

echo
ok "Cluster '${CLUSTER_NAME}' is up — you now own a cloud. ☁️"
info "Next steps:"
echo "   ./scripts/bootstrap-gitops.sh   # module 2: Gitea + ArgoCD"
echo "   ./scripts/seed-gitea.sh         # module 2: push this repo to your cloud"
info "Useful:"
echo "   talosctl --context ${CLUSTER_NAME} dashboard   # Talos node dashboard"
echo "   ./scripts/destroy-cluster.sh                          # tear it all down"
