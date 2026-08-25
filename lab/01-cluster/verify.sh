#!/usr/bin/env bash
# Module 01 — verify the Talos + Cilium cluster.
set -euo pipefail

FAILED=0
ok()   { echo "✅ $1"; }
fail() { echo "❌ FAIL: $1"; FAILED=$((FAILED + 1)); }

# --- Nodes exist at the substrate level -------------------------------------
# The one check in this file that cannot be substrate-blind: on docker the nodes
# are containers Talos labels talos.cluster.name=cloudbox; on tbx they are VMs
# only `tbx status` can see. Everything below this is plain kubectl and is
# identical on both — which is the whole point of the substrate contract.
SUBSTRATE="${CLOUDBOX_SUBSTRATE:-}"
if [ -z "$SUBSTRATE" ] && [ -r "$HOME/.cloudbox/substrate" ]; then
  SUBSTRATE="$(tr -d '[:space:]' < "$HOME/.cloudbox/substrate")"
fi
case "$SUBSTRATE" in tbx|docker) ;; *) SUBSTRATE=docker ;; esac

if [ "$SUBSTRATE" = tbx ]; then
  # `tbx status <cluster> -o json` prints a JSON ARRAY of ClusterStatus even for
  # one named cluster, so normalise before reading .nodes[].
  TBX_JSON="$(tbx status cloudbox -o json 2>/dev/null || true)"
  NODES="$(printf '%s' "$TBX_JSON" | jq -r '(if type == "array" then ((map(select(.name == "cloudbox")) | first) // {}) else . end) | [(.nodes // [])[] | select(.phase == "configured")] | length' 2>/dev/null || echo 0)"
  case "$NODES" in ''|*[!0-9]*) NODES=0 ;; esac
  if [ "$NODES" -ge 2 ]; then
    ok "cloudbox Talos VMs are running and configured (${NODES})"
  else
    PHASES="$(printf '%s' "$TBX_JSON" | jq -r '(if type == "array" then ((map(select(.name == "cloudbox")) | first) // {}) else . end) | [(.nodes // [])[] | "\(.role):\(.phase)"] | join(", ")' 2>/dev/null || true)"
    # Every node stopped or suspended is a cluster to START, not to re-create:
    # it is what a reboot or `tbx down` leaves behind, and "run
    # create-cluster.sh" there costs the attendee the cluster they still have.
    # The phases are talos-box's own (internal/daemon/phase.go).
    STOPPED="$(printf '%s' "$TBX_JSON" | jq -r '(if type == "array" then ((map(select(.name == "cloudbox")) | first) // {}) else . end) | (.nodes // []) | if length == 0 then "unknown" elif ([.[] | select(.phase != "stopped" and .phase != "suspended")] | length) == 0 then "all-stopped" else "some-running" end' 2>/dev/null || echo unknown)"
    if [ "$STOPPED" = all-stopped ]; then
      fail "the cloudbox VMs exist but are all stopped/suspended (${PHASES}) — start them, do not re-create: 'tbx cluster start cloudbox', then './scripts/create-cluster.sh --refresh-endpoint' (the VM addresses are DHCP leases and may have moved)"
    else
      fail "expected 2 configured Talos VMs, found ${NODES}${PHASES:+ (saw ${PHASES})} — 'tbx status cloudbox', then ./scripts/create-cluster.sh"
    fi
  fi
else
  # Filter on the talosctl-applied label — a name prefix would also match the
  # cloudbox-mirror registry container.
  # `|| CONTAINERS=0`: with `set -o pipefail` a stopped Docker daemon makes the
  # whole substitution non-zero, and `set -e` would kill this script BEFORE it
  # could print a single FAIL line — the attendee would get silence and exit 1.
  CONTAINERS="$(docker ps -q --filter "label=talos.cluster.name=cloudbox" 2>/dev/null | wc -l | tr -d ' ')" || CONTAINERS=0
  case "$CONTAINERS" in ''|*[!0-9]*) CONTAINERS=0 ;; esac
  if [ "${CONTAINERS:-0}" -ge 2 ]; then
    ok "cloudbox Talos node containers are running (${CONTAINERS})"
  else
    fail "expected 2 running Talos node containers, found ${CONTAINERS:-0} — run ./scripts/create-cluster.sh"
  fi
fi

# --- Workshop-context guard ------------------------------------------------
# Sourced HERE, not at the top of the file, and the ordering is deliberate: the
# docker check above is the one thing in this script that does not depend on a
# kubeconfig, and its message is module 01's teaching ("run create-cluster.sh").
# Everything BELOW this line talks to whatever cluster kubectl points at, which
# in rehearsal 3 was a 36-node corporate cluster this script happily graded
# ("want 2 Ready nodes, have 36/36") after destroy-cluster.sh removed the
# workshop context and kubectl fell through to the next entry in ~/.kube/config.
# The guard reads the kubeconfig only — a workshop cluster that is merely down
# still passes it, so the reachability check below keeps its own diagnosis.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "$DIR/../common.sh"

# --- kubectl reachability --------------------------------------------------
if kubectl version >/dev/null 2>&1; then
  ok "kubectl reaches the API server"
else
  # Do NOT suggest `talosctl kubeconfig` here. It writes the server address from
  # the machine config's cluster.controlPlane.endpoint — on the docker substrate
  # that is the node's in-network https://10.5.0.2:6443 (docker-only), which
  # only routes on native Linux. On macOS/Windows it replaces a working
  # kubeconfig with one that hangs on TCP connect. create-cluster.sh repoints the
  # context at whatever the substrate actually publishes — the controlplane
  # container's port on docker, the control-plane VM's own address on tbx —
  # so re-running it is the fix on both.
  fail "kubectl cannot reach the cluster — did create-cluster.sh finish? Re-run ./scripts/create-cluster.sh (it points the kubeconfig at the API server your substrate publishes: https://127.0.0.1:\$(docker port cloudbox-controlplane-1 6443/tcp) on docker, the control-plane VM's own address on tbx, read from 'tbx status ${CLUSTER_NAME} -o json' — a vmnet DHCP lease, not a computable .2)"
  echo; echo "❌ Cannot check further without API access."; exit 1
fi

# --- Nodes Ready -----------------------------------------------------------
NODES_TOTAL="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
NODES_READY="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l | tr -d ' ')"
if [ "$NODES_TOTAL" -eq 2 ] && [ "$NODES_READY" -eq 2 ]; then
  ok "2/2 nodes Ready"
else
  fail "want 2 Ready nodes, have ${NODES_READY}/${NODES_TOTAL} — 'kubectl describe node' the NotReady one; if CNI-related, check the cilium pods"
fi

# --- Cilium DaemonSet healthy ----------------------------------------------
DESIRED="$(kubectl -n kube-system get ds cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
READY="$(kubectl -n kube-system get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
if [ "${DESIRED:-0}" -gt 0 ] && [ "$DESIRED" = "$READY" ]; then
  ok "Cilium DaemonSet healthy (${READY}/${DESIRED})"
else
  fail "Cilium DaemonSet not healthy (${READY}/${DESIRED} ready) — kubectl -n kube-system get pods -l k8s-app=cilium; describe the bad pod"
fi

# --- Cilium operator -------------------------------------------------------
if kubectl -n kube-system wait --for=condition=Available deploy/cilium-operator --timeout=5s >/dev/null 2>&1; then
  ok "cilium-operator Available"
else
  fail "cilium-operator not Available — kubectl -n kube-system logs deploy/cilium-operator"
fi

# --- kube-proxy must be absent ---------------------------------------------
KP="$(kubectl -n kube-system get pods --no-headers 2>/dev/null | awk '/kube-proxy/ {n++} END {print n+0}')"
if [ "${KP:-0}" -eq 0 ]; then
  ok "no kube-proxy pods (Cilium eBPF handles Services)"
else
  fail "found ${KP} kube-proxy pod(s) — this cluster should be kube-proxy-free; was it created with ./scripts/create-cluster.sh?"
fi

# --- Cilium says it replaces kube-proxy -------------------------------------
if kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief >/dev/null 2>&1; then
  KPR="$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null | grep -i 'KubeProxyReplacement' | head -1 || true)"
  if echo "$KPR" | grep -qiE 'true|strict'; then
    ok "Cilium KubeProxyReplacement active"
  else
    fail "Cilium does not report KubeProxyReplacement active (${KPR:-no output}) — check the Helm values used by create-cluster.sh"
  fi
else
  fail "could not exec into a cilium pod to check status — kubectl -n kube-system get pods -l k8s-app=cilium"
fi

# --- CoreDNS up (proves pod networking + Services actually work) ------------
if kubectl -n kube-system wait --for=condition=Available deploy/coredns --timeout=5s >/dev/null 2>&1; then
  ok "CoreDNS Available (pod networking + Services work end to end)"
else
  fail "CoreDNS not Available — usually a CNI problem; kubectl -n kube-system get pods and look at coredns events"
fi

# --- Shared ingress ---------------------------------------------------------
# "There is one endpoint every *.cloudbox.k8s.test name lands on" is part of what
# module 01 delivers — but WHAT that endpoint is differs: a LoadBalancer VIP that
# Cilium hands out on tbx, a NodePort published on host port 80 on docker.
ING_TYPE="$(kubectl -n kube-system get svc cilium-ingress -o jsonpath='{.spec.type}' 2>/dev/null || true)"
if [ "$SUBSTRATE" = tbx ]; then
  VIP="$(kubectl -n kube-system get svc cilium-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  # Not just "has a VIP" — has the RIGHT one. talos-box's resolver answers
  # 172.30.<n>.200 for every *.cloudbox.k8s.test name unconditionally, without
  # consulting which Service holds that address, so an ingress anywhere else in
  # the .200-.239 pool means every workshop URL resolves to nothing while the
  # cluster looks entirely healthy. Matched on the .200 suffix: <n> is the
  # cluster's own subnet index and this check does not need to know it.
  case "$VIP" in
    "")
      fail "cilium-ingress has no LoadBalancer address (type ${ING_TYPE:-missing}) — kubectl get ciliumloadbalancerippools; kubectl -n kube-system describe svc cilium-ingress" ;;
    172.30.*.200)
      ok "shared ingress holds the VIP ${VIP} (every *.cloudbox.k8s.test name resolves here)" ;;
    *)
      fail "cilium-ingress holds ${VIP}, but talos-box's resolver answers .200 for every *.cloudbox.k8s.test name — no hostname reaches the ingress. Another LoadBalancer Service took .200: kubectl get svc -A --field-selector spec.type=LoadBalancer" ;;
  esac
else
  if [ "$ING_TYPE" = NodePort ]; then
    ok "shared ingress is a NodePort, published on host port 80"
  else
    fail "cilium-ingress is '${ING_TYPE:-missing}', want NodePort on the docker substrate — was the cluster made by ./scripts/create-cluster.sh?"
  fi
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED check(s) failed. Worst case is always fine: ./scripts/destroy-cluster.sh && ./scripts/create-cluster.sh"
  exit 1
fi
echo "✅ Module 01 complete — you own a cloud. Two-minute explain-back, then on to GitOps."
