#!/usr/bin/env bash
# Inject a fault into your cluster: ./inject.sh <1-4>
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sourcing common.sh runs the workshop-context guard. This script writes to the
# cluster kubectl points at, so it must refuse an unknown one before it does.
# shellcheck source=../common.sh
source "$DIR/../common.sh"

usage() {
  echo "usage: ./inject.sh <fault-number>"
  echo "faults:"
  for d in "$DIR"/faults/*/; do
    echo "  $(basename "$d")"
  done
  exit 1
}

[ $# -eq 1 ] || usage
printf -v NN '%02d' "$1" 2>/dev/null || usage

FAULT_DIR=""
for d in "$DIR/faults/$NN"-*/; do
  [ -d "$d" ] && FAULT_DIR="${d%/}" && break
done
[ -n "$FAULT_DIR" ] || { echo "ERROR: no fault $NN"; usage; }

# A fault namespace that already exists is almost certainly a RESTORED one, and
# re-applying issue.yaml over it does not reliably re-break anything. Measured,
# per fault, rather than assumed:
#   01  the Deployment has ONE replica and maxUnavailable: 25%, which rounds down
#       to 0 — so the rolling update never tears the healthy old pod down and the
#       Deployment stays Available with the broken spec sitting behind it.
#   02  the bad storageClassName lands on a Cluster whose PVC is already Bound,
#       and CNPG does not re-provision storage for an existing cluster.
# The apply is accepted and nothing breaks. You get a namespace with no fault in
# it — and verify.sh,
# which looks for the symptom, then reports the fault "fixed". Silently handing an
# attendee a confident wrong answer is precisely what this module is about, so it
# is not something to leave in the module's own tooling.
# ...but "exists" is not the same as "is in your way". `restore.sh clean` deletes
# with --wait=false, so the namespace is usually still Terminating when the
# attendee runs the very next line THIS script just told them to run. Refusing
# then would print the same two-line cure they had just followed — advice that
# argues with itself. Measured on an idle cluster: ~16 s, and longer whenever a
# CNPG cluster and its PVC are being finalized. So wait it out.
ns_phase() { kubectl get namespace "faultlab-$NN" -o jsonpath='{.status.phase}' 2>/dev/null; }
if [ "$(ns_phase)" = "Terminating" ]; then
  echo "namespace faultlab-$NN is still terminating from a previous ./restore.sh clean —"
  echo "waiting for it to go away (this is normal, usually a few seconds) ..."
  for _ in $(seq 1 90); do
    [ -n "$(ns_phase)" ] || break
    sleep 2
  done
  if [ "$(ns_phase)" = "Terminating" ]; then
    echo "namespace faultlab-$NN is STILL terminating after 3 minutes." >&2
    echo "Something in it has a finalizer that is not completing. Look at what is left:" >&2
    echo "  kubectl -n faultlab-$NN get all" >&2
    echo "  kubectl get namespace faultlab-$NN -o jsonpath='{.spec.finalizers}'" >&2
    exit 1
  fi
fi

if kubectl get namespace "faultlab-$NN" >/dev/null 2>&1; then
  echo "namespace faultlab-$NN already exists — this fault has been injected before." >&2
  echo >&2
  echo "Re-injecting over a restored namespace does not reliably re-break it, so" >&2
  echo "this would leave you debugging a cluster with nothing wrong with it." >&2
  echo "Start from a clean namespace instead:" >&2
  echo >&2
  echo "  ./restore.sh clean      # delete every fault namespace" >&2
  echo "  ./inject.sh $1" >&2
  exit 1
fi

if [ -x "$FAULT_DIR/issue.sh" ]; then
  "$FAULT_DIR/issue.sh"
else
  kubectl apply -f "$FAULT_DIR/issue.yaml" >/dev/null
fi

echo "💥 Fault $(basename "$FAULT_DIR") injected into namespace faultlab-$NN."
echo
echo "Your job: find it, prove it, fix it. Start with:"
echo "  kubectl -n faultlab-$NN get all"
echo
echo "NO PEEKING at faults/$(basename "$FAULT_DIR")/description.md or fix.yaml"
echo "until you have written down a diagnosis. Stuck for real? That file is the spoiler."
echo "Give up / done: ./restore.sh $1"
