#!/bin/bash

# This installs the MinIO operator for managing object storage

set -euo pipefail

echo "🪣 Installing MinIO Operator..."

# Check if we can connect to the cluster
echo "🔍 Checking cluster connectivity..."
mise exec -- kubectl cluster-info &> /dev/null || {
    echo "❌ Unable to connect to Kubernetes cluster"
    echo "Make sure you're connected to the correct cluster context"
    exit 1
}

echo "✅ Prerequisites check passed"

# Add the MinIO Helm repository
echo "📦 Adding MinIO Helm repository..."
mise exec -- helm repo add minio https://operator.min.io/

# Update Helm repositories
echo "🔄 Updating Helm repositories..."
mise exec -- helm repo update minio

# Install MinIO operator in minio-operator
echo "🚀 Installing MinIO operator in minio-operator..."
mise exec -- helm upgrade --install \
  --namespace minio-operator \
  --create-namespace \
  minio-operator minio/operator

# Wait for the operator to be ready
echo "⏳ Waiting for MinIO operator to be ready..."
mise exec -- kubectl wait --for=condition=Available deployment/minio-operator \
  --namespace minio-operator \
  --timeout=300s

echo "✅ MinIO operator installed successfully!"

echo ""
echo "💡 Useful commands:"
echo "  Check operator: mise exec -- kubectl get pods -n minio-operator"
echo "  View operator logs: mise exec -- kubectl logs -n minio-operator deployment/minio-operator"
echo ""
echo "📖 To create a MinIO tenant, use the install-minio-tenant.sh script"
