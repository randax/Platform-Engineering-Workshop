#!/bin/bash

# Strimzi Kafka Operator Installation Script
# This installs the Strimzi operator for managing Kafka clusters

set -e

echo "📨 Installing Strimzi Kafka Operator..."

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

# Add the Strimzi Helm repository
echo "📦 Adding Strimzi Helm repository..."
helm repo add strimzi https://strimzi.io/charts/

# Update Helm repositories
echo "🔄 Updating Helm repositories..."
helm repo update

# Install Strimzi operator
echo "🚀 Installing Strimzi Kafka operator..."
helm upgrade --install strimzi-kafka-operator \
  --namespace kafka-system \
  --create-namespace \
  strimzi/strimzi-kafka-operator

# Wait for the operator to be ready
echo "⏳ Waiting for Strimzi operator to be ready..."
kubectl wait --for=condition=Available deployment/strimzi-cluster-operator \
  --namespace kafka-system \
  --timeout=300s

echo "✅ Strimzi Kafka operator installed successfully!"
echo ""
echo "📋 Next steps:"
echo "   - Use the API/UI to create Kafka clusters"
echo "   - Check operator status: kubectl get pods -n kafka-system"
echo "   - View CRDs: kubectl get crd | grep kafka"
