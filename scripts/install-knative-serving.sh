#!/bin/bash

# Knative Serving Installation Script
# This installs Knative Serving for serverless functions

set -e

echo "⚡ Installing Knative Serving..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed or not in PATH"
    exit 1
fi

# Check if we can connect to the cluster
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Unable to connect to Kubernetes cluster"
    echo "Make sure you're connected to the correct cluster context"
    exit 1
fi

echo "✅ Prerequisites check passed"

# Install Knative Serving CRDs
echo "📦 Installing Knative Serving CRDs..."
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.11.0/serving-crds.yaml

# Install Knative Serving core components
echo "🚀 Installing Knative Serving core components..."
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.11.0/serving-core.yaml

# Install networking layer (Kourier)
echo "🌐 Installing Kourier networking layer..."
kubectl apply -f https://github.com/knative/net-kourier/releases/download/knative-v1.11.0/kourier.yaml

# Configure Knative to use Kourier
echo "⚙️ Configuring Knative to use Kourier..."
kubectl patch configmap/config-network \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'

# Configure Knative to skip tag resolution for internal registries
echo "� Configuring Knative to skip tag resolution for internal registries..."
kubectl patch configmap/config-deployment \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"registries-skipping-tag-resolving":"host.docker.internal:30500,zot-registry-internal.zot-registry:5000,localhost:30500,kind.local,ko.local,dev.local"}}'

# Wait for Knative to be ready
echo "⏳ Waiting for Knative Serving to be ready..."
kubectl wait --for=condition=Available deployment/controller \
  --namespace knative-serving \
  --timeout=300s

kubectl wait --for=condition=Available deployment/activator \
  --namespace knative-serving \
  --timeout=300s

kubectl wait --for=condition=Available deployment/webhook \
  --namespace knative-serving \
  --timeout=300s

echo "✅ Knative Serving installed successfully!"
echo ""
echo "📋 Next steps:"
echo "   - Use the API/UI to deploy serverless functions"
echo "   - Check Knative status: kubectl get pods -n knative-serving"
echo "   - View services: kubectl get ksvc -A"
