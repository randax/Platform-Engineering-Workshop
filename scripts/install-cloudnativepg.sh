#!/bin/bash

# CloudNativePG Installation Script
set -e

echo "🚀 Installing CloudNativePG operator..."

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

# Check if we're connected to the right cluster
CURRENT_CONTEXT=$(kubectl config current-context)
echo "📋 Current kubectl context: $CURRENT_CONTEXT"

if [[ "$CURRENT_CONTEXT" != "colima" ]]; then
    echo "⚠️  Warning: Not using 'colima' context. Current context is '$CURRENT_CONTEXT'"
    read -p "Do you want to continue? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Installation cancelled"
        exit 1
    fi
fi

# Add CloudNativePG Helm repository
echo "📦 Adding CloudNativePG Helm repository..."
helm repo add cnpg https://cloudnative-pg.github.io/charts

# Update Helm repositories
echo "🔄 Updating Helm repositories..."
helm repo update

# Install CloudNativePG operator
echo "⚙️  Installing CloudNativePG operator..."
helm upgrade --install cnpg \
  --namespace cnpg-system \
  --create-namespace \
  cnpg/cloudnative-pg \
  --wait

# Verify installation
echo "✅ Verifying CloudNativePG installation..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=cloudnative-pg -n cnpg-system --timeout=300s

# Show operator status
echo "📊 CloudNativePG operator status:"
kubectl get pods -n cnpg-system
kubectl get crd | grep postgresql

echo "🎉 CloudNativePG operator installed successfully!"
echo ""
echo "Next steps:"
echo "1. Create a PostgreSQL cluster: ./scripts/create-postgres-cluster.sh"
echo "2. Check cluster status: kubectl get clusters -n default"
echo "3. Connect to database: kubectl get secret <cluster-name>-app -o jsonpath='{.data.password}' | base64 -d"
