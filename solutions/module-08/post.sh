#!/usr/bin/env bash
# Imperative leftovers of module 03 that GitOps cannot carry: the app-assets
# bucket and one object in it. Run by catch-up.sh after ArgoCD has converged.
# Idempotent.
set -euo pipefail

for attempt in 1 2 3; do
  if kubectl -n demo run "catchup-s3-$$" --rm -i --restart=Never --quiet \
      --image=public.ecr.aws/aws-cli/aws-cli:2.27.49 \
      --env AWS_ACCESS_KEY_ID=cloudbox --env AWS_SECRET_ACCESS_KEY=cloudbox123 \
      --env AWS_REGION=us-east-1 \
      --command -- /bin/sh -c '
        set -e
        EP=http://rustfs-svc.rustfs.svc.cluster.local:9000
        aws --endpoint-url $EP s3api head-bucket --bucket app-assets 2>/dev/null \
          || aws --endpoint-url $EP s3 mb s3://app-assets
        echo "hello from my own cloud" > /tmp/hello.txt
        aws --endpoint-url $EP s3 cp /tmp/hello.txt s3://app-assets/hello.txt'; then
    echo "✅ bucket app-assets ready"
    exit 0
  fi
  echo "bucket setup attempt $attempt failed; retrying in 15s..." >&2
  sleep 15
done
echo "ERROR: could not create app-assets bucket — is rustfs healthy?" >&2
exit 1
