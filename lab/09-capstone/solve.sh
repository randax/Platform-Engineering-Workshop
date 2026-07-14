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
# portal.yaml is module 08's; re-copying is a no-op when it's already enabled,
# and makes this module solvable standalone (the upload goes through the portal).
enable_catalog "$CLONE" portal.yaml knative-eventing.yaml picture-pipeline.yaml
gitops_push "$CLONE" "module 09: knative-eventing + picture pipeline"

wait_app knative-eventing 600
wait_app portal
wait_app picture-pipeline 600

kubectl -n pipeline wait --for=condition=Ready broker/default --timeout=300s
kubectl -n pipeline wait --for=condition=Ready trigger/resize-on-upload --timeout=300s
kubectl -n pipeline wait --for=condition=Ready ksvc/uploader ksvc/resizer --timeout=300s
kubectl -n pipeline wait --for=condition=Complete job/create-images-bucket --timeout=300s

# Wait for the portal UI (the upload path goes browser → portal → uploader).
WAITED=0
until curl -fsS --max-time 5 -o /dev/null http://localhost:30600/healthz 2>/dev/null; do
  [ "$WAITED" -ge 300 ] && { echo "timed out waiting for the portal on :30600" >&2; exit 1; }
  sleep 10; WAITED=$((WAITED + 10))
done

# A 1x1 PNG, embedded so the solve needs no local image file.
PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
TMP_PNG="$(mktemp).png"
# shellcheck disable=SC2015  # macOS base64 wants -D on older releases
echo "$PNG_B64" | base64 -d > "$TMP_PNG" 2>/dev/null || echo "$PNG_B64" | base64 -D > "$TMP_PNG"

echo "uploading test image through the portal (cold-starts the uploader)..."
curl -fsS --max-time 120 -o /dev/null \
  -F "file=@${TMP_PNG};type=image/png;filename=solve-test.png" \
  http://localhost:30600/gallery/upload
rm -f "$TMP_PNG"

# The resizer scales from zero to process the event — poll S3 for its output.
s3() {
  if command -v aws >/dev/null 2>&1; then
    AWS_ACCESS_KEY_ID=cloudbox AWS_SECRET_ACCESS_KEY=cloudbox123 AWS_REGION=us-east-1 \
      aws --endpoint-url http://localhost:30900 "$@" 2>/dev/null
  else
    kubectl -n pipeline run "solve-s3-$$-${RANDOM}" --rm -i --restart=Never --quiet \
      --image=public.ecr.aws/aws-cli/aws-cli:2.27.49 \
      --env AWS_ACCESS_KEY_ID=cloudbox --env AWS_SECRET_ACCESS_KEY=cloudbox123 \
      --env AWS_REGION=us-east-1 \
      -- --endpoint-url http://rustfs-svc.rustfs.svc.cluster.local:9000 "$@" 2>/dev/null
  fi
}

echo "waiting for the resizer (scaling from zero) to write the thumbnail..."
WAITED=0
until s3 s3api list-objects-v2 --bucket images --prefix thumbs/ \
        --query 'Contents[].Key' --output text | grep -q thumbs/; do
  [ "$WAITED" -ge 240 ] && { echo "no thumbnail after ${WAITED}s — check: kubectl -n pipeline logs -l serving.knative.dev/service=resizer -c user-container" >&2; exit 1; }
  sleep 10; WAITED=$((WAITED + 10))
done
echo "thumbnail produced after ~${WAITED}s — see http://localhost:30600/gallery"
