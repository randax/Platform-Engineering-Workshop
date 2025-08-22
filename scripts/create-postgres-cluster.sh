#!/bin/bash

# PostgreSQL Cluster Creation Script
set -e

CLUSTER_NAME=${1:-"postgres-cluster"}
NAMESPACE=${2:-"default"}

echo "🐘 Creating PostgreSQL cluster: $CLUSTER_NAME in namespace: $NAMESPACE"

# Check if CloudNativePG operator is installed
if ! kubectl get crd clusters.postgresql.cnpg.io &> /dev/null; then
    echo "❌ CloudNativePG operator not found. Please run ./scripts/install-cloudnativepg.sh first"
    exit 1
fi

# Create PostgreSQL cluster manifest
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $CLUSTER_NAME
  namespace: $NAMESPACE
spec:
  instances: 3

  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"
      effective_cache_size: "1GB"
      wal_buffers: "16MB"
      checkpoint_completion_target: "0.9"
      random_page_cost: "1.1"
      effective_io_concurrency: "200"

  bootstrap:
    initdb:
      database: appdb
      owner: app
      secret:
        name: $CLUSTER_NAME-app-user

  storage:
    size: 1Gi
    storageClass: "local-path"

  resources:
    requests:
      memory: "256Mi"
      cpu: "100m"
    limits:
      memory: "512Mi"
      cpu: "500m"

  monitoring:
    enabled: true

  backup:
    retention: "30d"
    barmanObjectStore:
      destinationPath: "s3://backup-bucket/postgres"
      s3Credentials:
        accessKeyId:
          name: backup-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: backup-credentials
          key: SECRET_ACCESS_KEY
      wal:
        retention: "7d"

---
apiVersion: v1
kind: Secret
metadata:
  name: $CLUSTER_NAME-app-user
  namespace: $NAMESPACE
type: kubernetes.io/basic-auth
stringData:
  username: app
  password: $(openssl rand -base64 32)
EOF

echo "⏳ Waiting for PostgreSQL cluster to be ready..."
kubectl wait --for=condition=Ready cluster/$CLUSTER_NAME -n $NAMESPACE --timeout=600s

echo "📊 Cluster status:"
kubectl get cluster $CLUSTER_NAME -n $NAMESPACE
kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE

echo "🔑 Database connection details:"
echo "Host: $CLUSTER_NAME-rw.$NAMESPACE.svc.cluster.local"
echo "Port: 5432"
echo "Database: appdb"
echo "Username: app"
echo "Password: $(kubectl get secret $CLUSTER_NAME-app-user -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)"

echo "🎉 PostgreSQL cluster '$CLUSTER_NAME' created successfully!"
echo ""
echo "Connection examples:"
echo "# Port forward to access locally:"
echo "kubectl port-forward svc/$CLUSTER_NAME-rw 5432:5432 -n $NAMESPACE"
echo ""
echo "# Connect using psql:"
echo "PGPASSWORD=\$(kubectl get secret $CLUSTER_NAME-app-user -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d) psql -h localhost -p 5432 -U app -d appdb"
