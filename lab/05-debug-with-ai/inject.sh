#!/usr/bin/env bash
# Inject a fault into your cluster: ./inject.sh <1-4>
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# re-applying issue.yaml over it does not reliably re-break anything: some of the
# fields these faults corrupt are immutable once created, so the apply is accepted
# and changes nothing. You get a namespace with no fault in it — and verify.sh,
# which looks for the symptom, then reports the fault "fixed". Silently handing an
# attendee a confident wrong answer is precisely what this module is about, so it
# is not something to leave in the module's own tooling.
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
