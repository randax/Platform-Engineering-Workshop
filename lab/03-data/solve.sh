#!/usr/bin/env bash
# Module 03 — full solution: enable cnpg + rustfs, deliver app-db via git,
# create the app-assets bucket with an object in it.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
# shellcheck source=../common.sh
source "$REPO_ROOT/lab/common.sh"

# 1. Enable the catalog apps + deliver the database manifest, all in one push.
CLONE="$(gitops_clone)"
enable_catalog "$CLONE" cnpg-operator.yaml rustfs.yaml
mkdir -p "$CLONE/gitops/components/demo"
cp "$LAB_DIR/postgres-cluster.yaml" "$CLONE/gitops/components/demo/postgres-cluster.yaml"
gitops_push "$CLONE" "module 03: enable cnpg-operator + rustfs, add app-db"

wait_app cnpg-operator
wait_app rustfs
wait_app demo

# 2. Wait for the database to be genuinely healthy, prove it with SELECT 1.
kubectl -n demo wait --for=condition=Ready cluster/app-db --timeout=420s
kubectl -n demo exec app-db-1 -- psql -U postgres -d app -tAc 'SELECT 1;'

# 3. Bucket + object + presigned URL. Uses local aws CLI when present,
#    otherwise an in-cluster aws-cli pod.
if command -v aws >/dev/null 2>&1; then
  export AWS_ACCESS_KEY_ID=cloudbox AWS_SECRET_ACCESS_KEY=cloudbox123 AWS_REGION=us-east-1
  aws --endpoint-url http://localhost:30900 s3 mb s3://app-assets 2>/dev/null || true
  echo "hello from my own cloud" > /tmp/cloudbox-hello.txt
  aws --endpoint-url http://localhost:30900 s3 cp /tmp/cloudbox-hello.txt s3://app-assets/hello.txt
  aws --endpoint-url http://localhost:30900 s3 presign s3://app-assets/hello.txt --expires-in 3600
else
  kubectl -n demo run solve-s3 --rm -i --restart=Never --quiet \
    --image=public.ecr.aws/aws-cli/aws-cli:2.27.49 \
    --env AWS_ACCESS_KEY_ID=cloudbox --env AWS_SECRET_ACCESS_KEY=cloudbox123 \
    --env AWS_REGION=us-east-1 \
    --command -- /bin/sh -c '
      set -e
      EP=http://rustfs-svc.rustfs.svc.cluster.local:9000
      aws --endpoint-url $EP s3 mb s3://app-assets 2>/dev/null || true
      echo "hello from my own cloud" > /tmp/hello.txt
      aws --endpoint-url $EP s3 cp /tmp/hello.txt s3://app-assets/hello.txt
      aws --endpoint-url $EP s3 presign s3://app-assets/hello.txt --expires-in 3600'
fi
