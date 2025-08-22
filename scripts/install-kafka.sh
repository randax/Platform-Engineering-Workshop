#!/bin/bash

# Kafka (Strimzi) Installation Script
set -e

echo "🚀 Installing Strimzi Kafka operator..."

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

# Check current context
CURRENT_CONTEXT=$(kubectl config current-context)
echo "📋 Current kubectl context: $CURRENT_CONTEXT"

# Add Strimzi Helm repository
echo "📦 Adding Strimzi Helm repository..."
helm repo add strimzi https://strimzi.io/charts/

# Update Helm repositories
echo "🔄 Updating Helm repositories..."
helm repo update

# Install Strimzi Kafka operator
echo "⚙️  Installing Strimzi Kafka operator..."
helm upgrade --install strimzi-kafka-operator \
  --namespace kafka \
  --create-namespace \
  strimzi/strimzi-kafka-operator \
  --wait

# Verify installation
echo "✅ Verifying Strimzi installation..."
kubectl wait --for=condition=Ready pod -l name=strimzi-cluster-operator -n kafka --timeout=300s

# Show operator status
echo "📊 Strimzi operator status:"
kubectl get pods -n kafka
kubectl get crd | grep kafka

echo "🎉 Strimzi Kafka operator installed successfully!"
echo ""
echo "Next steps:"
echo "1. Create a Kafka cluster: ./scripts/create-kafka-cluster.sh"
echo "2. Check cluster status: kubectl get kafka -n kafka"
echo "3. Create topics: kubectl apply -f manifests/kafka-topics.yaml"
