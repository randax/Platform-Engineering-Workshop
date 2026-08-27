#!/usr/bin/env bash
# Module 09 — verify the event-driven picture pipeline: eventing up, broker +
# trigger + ksvcs Ready, bucket present, and (if anything was uploaded) that
# originals produced thumbnails.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sourcing common.sh runs the workshop-context guard — this script must never
# report on a cluster that is not the workshop's (rehearsal 3: verify.sh cheerfully
# graded a 36-node corporate cluster). Guard first, then check.
# shellcheck source=../common.sh
source "$DIR/../common.sh"

FAILED=0
ok()   { echo "✅ $1"; }
fail() { echo "❌ FAIL: $1"; FAILED=$((FAILED + 1)); }

check_app() { # <name>
  # HEALTH is the real signal (workloads running); sync is advisory. Poll ~180s so
  # a transient OutOfSync/Progressing/Degraded while the app reconciles under CI
  # load rides out, instead of failing on a single point-in-time sample.
  local st sync health i
  for i in $(seq 1 36); do
    st="$(kubectl -n argocd get application "$1" \
      -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || echo missing)"
    # Fast-fail the missing case: if the app doesn't exist yet, don't stare at the
    # full 180s poll — an attendee who runs verify.sh before enabling the catalog
    # item should get instant feedback. Allow ~10s (two iterations) for a
    # just-created app to register, then fall through to the fail below.
    case "$st" in
      missing|"missing missing"|"") [ "$i" -ge 2 ] && break ;;
    esac
    health="${st##* }"
    if [ "$health" = "Healthy" ]; then
      sync="${st%% *}"
      if [ "$sync" = "Synced" ]; then ok "ArgoCD app '$1' is Synced/Healthy"
      else ok "ArgoCD app '$1' is Healthy (sync: ${sync:-unknown})"; fi
      return 0
    fi
    sleep 5
  done
  fail "app '$1' is '$st' — cp gitops/catalog/$1.yaml to gitops/apps/ and push"
}

# --- The two apps ---------------------------------------------------------------
check_app knative-eventing
check_app picture-pipeline

# --- Eventing control plane + broker data plane ----------------------------------
for d in eventing-controller eventing-webhook mt-broker-ingress mt-broker-filter imc-dispatcher; do
  if kubectl -n knative-eventing wait --for=condition=Available "deploy/$d" --timeout=5s >/dev/null 2>&1; then
    ok "knative-eventing/$d Available"
  else
    fail "knative-eventing/$d not Available — kubectl -n knative-eventing get pods"
  fi
done

# --- Broker + Trigger --------------------------------------------------------------
BROKER_READY="$(kubectl -n pipeline get broker default \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [ "$BROKER_READY" = "True" ]; then
  ok "Broker pipeline/default is Ready"
elif [ -z "$BROKER_READY" ]; then
  fail "no Broker 'default' in ns pipeline — is picture-pipeline synced? kubectl -n pipeline get broker"
else
  fail "Broker default not Ready — kubectl -n pipeline describe broker default (is eventing fully up?)"
fi

TRIG_READY="$(kubectl -n pipeline get trigger resize-on-upload \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [ "$TRIG_READY" = "True" ]; then
  ok "Trigger resize-on-upload is Ready (filters type dev.cloudbox.image.uploaded → resizer)"
else
  fail "Trigger resize-on-upload is '${TRIG_READY:-missing}' — kubectl -n pipeline describe trigger resize-on-upload"
fi

# --- The two Knative Services --------------------------------------------------------
for s in uploader resizer; do
  KSVC_READY="$(kubectl -n pipeline get ksvc "$s" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [ "$KSVC_READY" = "True" ]; then
    ok "ksvc $s is Ready (cluster-local, scales from zero)"
  else
    fail "ksvc $s is '${KSVC_READY:-missing}' — kubectl -n pipeline describe ksvc $s"
  fi
done

# --- Bucket + outcome ------------------------------------------------------------------
# s5cmd locally against the NodePort if available, else the in-cluster
# pattern from module 03.
s3() {
  if command -v s5cmd >/dev/null 2>&1; then
    AWS_ACCESS_KEY_ID=cloudbox AWS_SECRET_ACCESS_KEY=cloudbox123 AWS_REGION=eu-north-1 \
      s5cmd --endpoint-url "${RUSTFS_S3_HOST_URL}" "$@" 2>/dev/null
  else
    kubectl -n pipeline run "verify-s3-$$-${RANDOM}" --rm -i --restart=Never --quiet \
      --image=docker.io/peakcom/s5cmd:v2.3.0 \
      --env AWS_ACCESS_KEY_ID=cloudbox --env AWS_SECRET_ACCESS_KEY=cloudbox123 \
      --env AWS_REGION=eu-north-1 \
      -- --endpoint-url http://rustfs-svc.rustfs.svc.cluster.local:9000 "$@" 2>/dev/null
  fi
}

# `ls s3://<bucket>` is s5cmd's head-bucket: exit 0 if it exists (even empty),
# exit 1 + NoSuchBucket if not.
if s3 ls s3://images >/dev/null; then
  ok "bucket 'images' exists in RustFS"
else
  fail "bucket 'images' not found — kubectl -n pipeline logs job/create-images-bucket (is rustfs up?)"
fi

list_keys() { # <prefix>
  # s5cmd's plain `ls` prints "date size basename" relative to the prefix, so
  # --show-fullpath is what turns it into keys: it emits the full s3:// URI per
  # object, recursively, and the sed strips the bucket back off. Result is
  # byte-identical to what `list-objects-v2 --query 'Contents[].Key'` produced.
  #
  # Two exit-1 cases are legitimate "not yet, keep waiting", not errors: an
  # absent prefix ("no object found") and, before the Job lands, a missing
  # bucket. `sed -n …p` only prints lines that matched, so s5cmd's ERROR line —
  # which kubectl folds into stdout — is dropped without a second filter.
  # `|| true` because those exit-1 cases must not trip `set -e`/pipefail.
  # One retry on an empty result, for the other half of the `kubectl run -i`
  # race the comment above describes: the pod can exit before the attach lands
  # and kubectl then loses the container's stdout altogether, so a prefix that
  # HAS objects lists as empty and the capstone reports "no matching thumbs/"
  # on a pipeline that worked. Print nothing (not a blank line) when the prefix
  # really is empty — callers test with [ -z ... ].
  local out
  out="$(s3 ls --show-fullpath "s3://images/$1" | sed -n 's|^s3://images/||p' || true)"
  if [ -z "$out" ]; then
    sleep 2
    out="$(s3 ls --show-fullpath "s3://images/$1" | sed -n 's|^s3://images/||p' || true)"
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

ORIGINALS="$(list_keys originals/)"
if [ -z "$ORIGINALS" ]; then
  echo "○ star task not done yet: upload a photo at ${PORTAL_HOST_URL}/gallery (watch kubectl -n pipeline get pods -w) — verify passes without it, but the capstone moment is missing"
else
  THUMBS="$(list_keys thumbs/)"
  MATCHED=""
  while IFS= read -r key; do
    # resizer writes originals/<base> → thumbs/<base>.jpg; match on the stem
    # so an extension swap still counts (escape regex metachars, e.g. dots).
    stem="${key#originals/}"; stem="${stem%.*}"
    stem_re="$(printf '%s' "$stem" | sed 's/[.[\*^$]/\\&/g')"
    if printf '%s\n' "$THUMBS" | grep -q "^thumbs/${stem_re}"; then
      MATCHED="$key"
      break
    fi
  done <<<"$ORIGINALS"
  if [ -n "$MATCHED" ]; then
    ok "upload processed: ${MATCHED} has a matching thumbnail under thumbs/"
  else
    fail "originals/ has objects but no matching thumbs/ — the resizer never ran? kubectl -n pipeline logs -l serving.knative.dev/service=resizer -c user-container; then hint 2"
  fi
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED check(s) failed."
  exit 1
fi
echo "✅ Module 09 complete — an event-driven pipeline, on hardware you own. That's the whole tour."
