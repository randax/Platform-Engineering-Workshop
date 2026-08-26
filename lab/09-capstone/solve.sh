#!/usr/bin/env bash
# Module 09 — full solution: enable eventing + the picture pipeline, then
# upload a tiny test PNG through the portal (plain curl — the gallery form is
# just a multipart POST) so the outcome check in verify.sh is unconditional.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
# shellcheck source=../common.sh
source "$REPO_ROOT/lab/common.sh"

CLONE="$(gitops_clone)"
# knative-serving.yaml (module 06) and portal.yaml (module 08) are earlier
# modules' apps; re-copying is a no-op when they're already enabled, and makes
# this module solvable standalone (the ksvcs need Serving, the upload goes
# through the portal).
enable_catalog "$CLONE" knative-serving.yaml portal.yaml knative-eventing.yaml picture-pipeline.yaml
gitops_push "$CLONE" "module 09: knative-eventing + picture pipeline"

wait_app knative-serving 600
wait_app knative-eventing 600
wait_app portal
wait_app picture-pipeline 600

# The picture-pipeline app can be Healthy before every resource is applied
# (wait_app keys on health; sync may lag) — guard each condition-wait with an
# existence-wait so a not-yet-created resource doesn't hard-fail the wait.
wait_exists pipeline broker/default
wait_exists pipeline ksvc/uploader
wait_exists pipeline ksvc/resizer
wait_exists pipeline trigger/resize-on-upload
kubectl -n pipeline wait --for=condition=Ready broker/default --timeout=300s
# Wait for the subscriber ksvcs BEFORE the trigger. A Knative Trigger only goes
# Ready once BOTH its broker AND its subscriber (the resizer ksvc) are
# address-resolvable — so waiting on the trigger before its subscriber is a race
# that intermittently timed out under CI load. Order the dependency correctly.
kubectl -n pipeline wait --for=condition=Ready ksvc/uploader ksvc/resizer --timeout=300s
# The trigger latches "BrokerNotConfigured" if it first reconciled before the
# broker was Ready (the broker itself races the eventing-config install). With the
# broker AND subscriber now up, poke the trigger to re-reconcile so it picks them
# up. The timestamp guarantees the annotation actually changes (forcing a
# reconcile) even on a re-run; ArgoCD selfHeal reverts it afterwards.
kubectl -n pipeline annotate trigger/resize-on-upload \
  cloudbox.io/rereconcile="$(date +%s)" --overwrite >/dev/null 2>&1 || true
kubectl -n pipeline wait --for=condition=Ready trigger/resize-on-upload --timeout=300s
wait_exists pipeline job/create-images-bucket
kubectl -n pipeline wait --for=condition=Complete job/create-images-bucket --timeout=300s

# Wait for the portal UI (the upload path goes browser → portal → uploader).
WAITED=0
until curl -fsS --max-time 5 -o /dev/null "${PORTAL_HOST_URL}/healthz" 2>/dev/null; do
  [ "$WAITED" -ge 300 ] && { echo "timed out waiting for the portal at ${PORTAL_HOST_URL}" >&2; exit 1; }
  sleep 10; WAITED=$((WAITED + 10))
done

# A 1x1 PNG, embedded so the solve needs no local image file.
PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
TMP_PNG="$(mktemp).png"
# shellcheck disable=SC2015  # macOS base64 wants -D on older releases
echo "$PNG_B64" | base64 -d > "$TMP_PNG" 2>/dev/null || echo "$PNG_B64" | base64 -D > "$TMP_PNG"

echo "uploading test image through the portal (cold-starts the uploader)..."
# The portal's upload handler renders the gallery-grid FRAGMENT with HTTP 200 in
# every branch — success and failure alike (apps/portal/internal/web/gallery.go).
# So `-o /dev/null` would throw away the only evidence that the proxied POST to
# the uploader failed, and the run would instead die 240s later on "no
# thumbnail" with the real error text nowhere in any log. Keep the body and read
# the flash: errorFlash() renders class="flash flash-error", the success flash
# renders plain class="flash".
UPLOAD_OUT="$(mktemp)"
UPLOAD_CODE="$(curl -sS --max-time 120 -o "$UPLOAD_OUT" -w '%{http_code}' \
  -F "file=@${TMP_PNG};type=image/png;filename=solve-test.png" \
  "${PORTAL_HOST_URL}/gallery/upload")" || UPLOAD_CODE="000 (curl transport error)"
rm -f "$TMP_PNG"

if [ "$UPLOAD_CODE" != "200" ] || grep -q 'flash-error' "$UPLOAD_OUT"; then
  {
    echo "❌ FAIL: the portal could not hand the upload to the uploader (HTTP ${UPLOAD_CODE})."
    echo "portal said:"
    # The flash carries the Go error verbatim ("dial tcp …", "lookup …") — print
    # it stripped of markup first, then the whole fragment for context.
    grep -o 'class="flash flash-error">[^<]*' "$UPLOAD_OUT" | sed 's/^[^>]*>/  /' || true
    echo "--- response body ---"
    cat "$UPLOAD_OUT"
    echo "---------------------"
    echo "the portal POSTs to \${UPLOADER_URL}/upload, default"
    echo "  http://uploader.pipeline.svc.cluster.local/upload"
    echo "(a Knative ExternalName -> kourier-internal.kourier-system). Probe it from inside"
    echo "the cluster to tell DNS from connect — the portal image is FROM scratch, so use a"
    echo "throwaway busybox rather than exec'ing into it:"
    echo "  kubectl -n portal run probe-\$RANDOM --rm -i --restart=Never --image=docker.io/library/busybox:1.37.0 \\"
    echo "    -- sh -c 'nslookup uploader.pipeline.svc.cluster.local; wget -qO- --timeout=5 http://uploader.pipeline.svc.cluster.local/healthz; echo rc=\$?'"
    echo "  kubectl -n pipeline get svc uploader -o yaml   # the ExternalName target"
    echo "  kubectl -n kourier-system get svc,pods -o wide"
  } >&2
  rm -f "$UPLOAD_OUT"
  exit 1
fi
rm -f "$UPLOAD_OUT"

# The resizer scales from zero to process the event — poll S3 for its output.
s3() {
  if command -v s5cmd >/dev/null 2>&1; then
    AWS_ACCESS_KEY_ID=cloudbox AWS_SECRET_ACCESS_KEY=cloudbox123 AWS_REGION=us-east-1 \
      s5cmd --endpoint-url "${RUSTFS_S3_HOST_URL}" "$@" 2>/dev/null
  else
    kubectl -n pipeline run "solve-s3-$$-${RANDOM}" --rm -i --restart=Never --quiet \
      --image=docker.io/peakcom/s5cmd:v2.3.0 \
      --env AWS_ACCESS_KEY_ID=cloudbox --env AWS_SECRET_ACCESS_KEY=cloudbox123 \
      --env AWS_REGION=us-east-1 \
      -- --endpoint-url http://rustfs-svc.rustfs.svc.cluster.local:9000 "$@" 2>/dev/null
  fi
}

echo "waiting for the resizer (scaling from zero) to write the thumbnail..."
WAITED=0
# --show-fullpath makes s5cmd print keys rather than "date size basename"; the
# anchored grep is also what discards its ERROR line while the prefix is still
# empty (kubectl folds the container's stderr into stdout). Capture before
# matching: while thumbs/ is empty s5cmd exits 1 ("no object found"), and under
# `pipefail` that would outrank grep and could never let the loop finish.
thumb_landed() {
  local out
  out="$(s3 ls --show-fullpath "s3://images/thumbs/" || true)"
  printf '%s\n' "$out" | grep -q '^s3://images/thumbs/'
}
until thumb_landed; do
  [ "$WAITED" -ge 240 ] && { echo "no thumbnail after ${WAITED}s — check: kubectl -n pipeline logs -l serving.knative.dev/service=resizer -c user-container" >&2; exit 1; }
  sleep 10; WAITED=$((WAITED + 10))
done
echo "thumbnail produced after ~${WAITED}s — see ${PORTAL_HOST_URL}/gallery"
