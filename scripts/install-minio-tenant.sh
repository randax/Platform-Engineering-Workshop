#!/bin/bash

# MinIO Tenant Installation Script for CloudBox
# This creates a MinIO tenant in cloudbox-system namespace

set -euo pipefail

echo "🪣 Installing CloudBox MinIO Tenant..."

# Check if we can connect to the cluster
echo "🔍 Checking cluster connectivity..."
mise exec -- kubectl cluster-info &> /dev/null || {
    echo "❌ Unable to connect to Kubernetes cluster"
    echo "Make sure you're connected to the correct cluster context"
    exit 1
}

# Check if MinIO operator is running
echo "🔍 Checking MinIO operator..."
mise exec -- kubectl get deployment minio-operator -n minio-operator &> /dev/null || {
    echo "❌ MinIO operator not found in minio-operator namespace"
    echo "Please run install-minio-operator.sh first"
    exit 1
}

echo "✅ Prerequisites check passed"

# Create a MinIO tenant in cloudbox-system namespace
echo ""
echo "🏗️  Creating CloudBox MinIO tenant..."

# Generate random credentials
MINIO_ROOT_USER="admin"
MINIO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

# Create configuration secret with proper format for MinIO operator
echo "🔐 Creating MinIO configuration secret..."
cat > /tmp/minio-config.env << EOF
export MINIO_ROOT_USER="$MINIO_ROOT_USER"
export MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD"
export MINIO_BROWSER_REDIRECT_URL="http://localhost:9001"
export MINIO_PROMETHEUS_AUTH_TYPE="public"
EOF

mise exec -- kubectl create secret generic cloudbox-minio-config \
  --namespace=cloudbox-system \
  --from-file=config.env=/tmp/minio-config.env \
  --dry-run=client -o yaml | mise exec -- kubectl apply -f -

echo "🛠️ Creating MinIO tenant configuration..."
cat > /tmp/cloudbox-minio-tenant.yaml << EOF
apiVersion: minio.min.io/v2
kind: Tenant
metadata:
  name: cloudbox-storage
  namespace: cloudbox-system
  labels:
    app.kubernetes.io/name: cloudbox-minio
    app.kubernetes.io/component: storage
    app.kubernetes.io/part-of: cloudbox-platform
spec:
  image: quay.io/minio/minio:RELEASE.2024-07-16T23-46-41Z
  configuration:
    name: cloudbox-minio-config
  pools:
  - servers: 1
    name: pool-0
    volumesPerServer: 1
    volumeClaimTemplate:
      metadata:
        name: data
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 1Gi
        storageClassName: "local-path"
    resources:
      requests:
        memory: 256Mi
        cpu: 100m
      limits:
        memory: 512Mi
        cpu: 250m
    securityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
  mountPath: /export
  subPath: /data
  requestAutoCert: false
  features:
    bucketDNS: false
  podManagementPolicy: Parallel
  serviceMetadata:
    minioServiceLabels:
      app.kubernetes.io/name: cloudbox-minio-service
  prometheusOperator: false
  logging:
    anonymous: true
    json: true
  serviceAccountName: ""
EOF

# Apply the MinIO tenant
echo "🚀 Creating MinIO tenant..."
mise exec -- kubectl apply -f /tmp/cloudbox-minio-tenant.yaml

# Wait for the tenant to be ready
echo "⏳ Waiting for MinIO tenant to be ready..."
sleep 10
mise exec -- kubectl wait --for=condition=Ready \
  --selector=app=minio \
  --timeout=300s pod || {
  echo "⚠️  MinIO pods may still be starting, check status with:"
  echo "    mise exec -- kubectl get pods -n cloudbox-system"
}

# Create a service for internal access
echo "🔗 Creating internal MinIO service..."
cat << 'EOF' | mise exec -- kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: cloudbox-minio-internal
  namespace: cloudbox-system
  labels:
    app.kubernetes.io/name: cloudbox-minio-internal
    app.kubernetes.io/component: storage
spec:
  type: ClusterIP
  ports:
    - port: 9000
      targetPort: 9000
      protocol: TCP
      name: api
    - port: 9001
      targetPort: 9001
      protocol: TCP
      name: console
  selector:
    app: minio
EOF

# Create ConfigMap with MinIO configuration for other services
echo "📝 Creating MinIO configuration ConfigMap..."
cat << 'EOF' | mise exec -- kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudbox-minio-config-map
  namespace: cloudbox-system
  labels:
    app.kubernetes.io/name: cloudbox-minio-config-map
    app.kubernetes.io/component: config
data:
  endpoint: "cloudbox-minio-internal.cloudbox-system:9000"
  console.endpoint: "cloudbox-minio-internal.cloudbox-system:9001"
  region: "us-east-1"
  secure: "false"
  namespace: "cloudbox-system"
  tenant.name: "cloudbox-storage"
EOF

# Clean up temporary files
rm -f /tmp/cloudbox-minio-tenant.yaml /tmp/minio-config.env

echo ""
echo "✅ CloudBox MinIO tenant installed successfully!"
echo ""
echo "📊 MinIO Tenant Information:"
echo "  Tenant Namespace: cloudbox-system"
echo "  Tenant Name: cloudbox-storage"
echo "  Internal API: cloudbox-minio-internal.cloudbox-system:9000"
echo "  Internal Console: cloudbox-minio-internal.cloudbox-system:9001"
echo "  Root User: $MINIO_ROOT_USER"
echo "  Root Password: $MINIO_ROOT_PASSWORD"
echo ""
echo "🔧 Next steps:"
echo "  1. Access MinIO console via port-forward:"
echo "     mise exec -- kubectl port-forward -n cloudbox-system svc/cloudbox-minio-internal 9001:9001"
echo "  2. Then visit: http://localhost:9001"
echo "  3. Use the credentials above to log in"
echo ""
echo "💡 Useful commands:"
echo "  Check tenant: mise exec -- kubectl get pods -n cloudbox-system"
echo "  View tenant: mise exec -- kubectl get tenant cloudbox-storage -n cloudbox-system"
echo "  Get config secret: mise exec -- kubectl get secret cloudbox-minio-config -n cloudbox-system -o yaml"
echo "  Check logs: mise exec -- kubectl logs -l app=minio -n cloudbox-system"
