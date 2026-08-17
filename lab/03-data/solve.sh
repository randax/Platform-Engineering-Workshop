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
# The demo app can report Synced without creating app-db if it synced before
# CNPG's CRD was Established (SkipDryRunOnMissingResource) — a race that leaves
# cluster/app-db missing. Wait for the CRD first, then make sure the Cluster
# actually materializes before waiting on its readiness.
kubectl wait --for=condition=Established crd/clusters.postgresql.cnpg.io --timeout=180s
wait_app rustfs
wait_app demo

# 2. Wait for the database to be genuinely healthy, prove it with SELECT 1.
# Nudge the demo app in case it first-synced before the CRD existed, then
# wait for the Cluster object to appear (self-heal applies it once it can).
kubectl -n argocd annotate application demo argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  kubectl -n demo get cluster/app-db >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n demo wait --for=condition=Ready cluster/app-db --timeout=420s
kubectl -n demo exec app-db-1 -- psql -U postgres -d app -tAc 'SELECT 1;'

# 3. Bucket + object + presigned URL. Uses a local s5cmd when present,
#    otherwise an in-cluster s5cmd pod.
if command -v s5cmd >/dev/null 2>&1; then
  export AWS_ACCESS_KEY_ID=cloudbox AWS_SECRET_ACCESS_KEY=cloudbox123 AWS_REGION=us-east-1
  s5cmd --endpoint-url http://localhost:30900 ls s3://app-assets >/dev/null 2>&1 \
    || s5cmd --endpoint-url http://localhost:30900 mb s3://app-assets
  echo "hello from my own cloud" > /tmp/cloudbox-hello.txt
  s5cmd --endpoint-url http://localhost:30900 cp /tmp/cloudbox-hello.txt s3://app-assets/hello.txt
  s5cmd --endpoint-url http://localhost:30900 presign --expire 1h s3://app-assets/hello.txt
else
  kubectl -n demo run solve-s3 --rm -i --restart=Never --quiet \
    --image=docker.io/peakcom/s5cmd:v2.3.0 \
    --env AWS_ACCESS_KEY_ID=cloudbox --env AWS_SECRET_ACCESS_KEY=cloudbox123 \
    --env AWS_REGION=us-east-1 \
    --command -- /bin/sh -c '
      set -e
      EP=http://rustfs-svc.rustfs.svc.cluster.local:9000
      /s5cmd --endpoint-url $EP ls s3://app-assets >/dev/null 2>&1 \
        || /s5cmd --endpoint-url $EP mb s3://app-assets
      echo "hello from my own cloud" > /tmp/hello.txt
      /s5cmd --endpoint-url $EP cp /tmp/hello.txt s3://app-assets/hello.txt
      /s5cmd --endpoint-url $EP presign --expire 1h s3://app-assets/hello.txt'
fi
