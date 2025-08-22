#!/bin/bash

# CloudNativePG Operator Installation Script
# This installs the CloudNativePG operator for managing PostgreSQL clusters

set -e

echo "🐘 Installing CloudNativePG Operator..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed or not in PATH"
    exit 1
fi

# Check if helm is available
if ! command -v helm &> /dev/null; then
    echo "❌ helm is not installed or not in PATH"
    exit 1
fi

# Check if we can connect to the cluster
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Unable to connect to Kubernetes cluster"
    echo "Make sure you're connected to the correct cluster context"
    exit 1
fi

echo "✅ Prerequisites check passed"

# Add the CloudNativePG Helm repository
echo "📦 Adding CloudNativePG Helm repository..."
helm repo add cnpg https://cloudnative-pg.github.io/charts

# Update Helm repositories
echo "🔄 Updating Helm repositories..."
helm repo update

# Install CloudNativePG operator
echo "🚀 Installing CloudNativePG operator..."
helm upgrade --install cnpg \
  --namespace cnpg-system \
  --create-namespace \
  cnpg/cloudnative-pg

# Wait for the operator to be ready
echo "⏳ Waiting for CloudNativePG operator to be ready..."
kubectl wait --for=condition=Available deployment/cnpg-cloudnative-pg \
  --namespace cnpg-system \
  --timeout=300s

echo "✅ CloudNativePG operator installed successfully!"
echo ""
echo "📋 Next steps:"
echo "   - Use the API/UI to create PostgreSQL clusters"
echo "   - Check operator status: kubectl get pods -n cnpg-system"
echo "   - View CRDs: kubectl get crd | grep postgresql"
