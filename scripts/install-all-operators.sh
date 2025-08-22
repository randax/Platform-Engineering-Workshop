#!/bin/bash

# Master Installation Script
# This script installs all the required operators for the CloudBox platform

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚀 CloudBox Platform - Installing All Operators"
echo "=============================================="
echo ""

# Make all scripts executable
chmod +x "$SCRIPT_DIR"/*.sh

echo "📋 Installing operators in the following order:"
echo "   1. CloudNativePG (PostgreSQL)"
echo "   2. Strimzi Kafka"
echo "   3. MinIO Operator (Object Storage)"
echo "   4. Zot Container Registry"
echo "   5. Knative Serving (Serverless Functions)"
echo "   6. Tekton Pipelines (CI/CD)"
echo ""

# Install CloudNativePG
echo "🐘 [1/5] Installing CloudNativePG..."
"$SCRIPT_DIR/install-cloudnative-pg.sh"
echo ""

# Install Strimzi Kafka
echo "📨 [2/5] Installing Strimzi Kafka..."
"$SCRIPT_DIR/install-strimzi-kafka.sh"
echo ""

# Install MinIO Operator
echo "🪣 [3/5] Installing MinIO Operator..."
"$SCRIPT_DIR/install-minio-operator.sh"
echo ""

# Install Zot Registry
echo "📦 [4/5] Installing Zot Container Registry..."
"$SCRIPT_DIR/install-zot.sh"
echo ""

# Install Knative Serving
echo "⚡ [5/6] Installing Knative Serving..."
"$SCRIPT_DIR/install-knative-serving.sh"
echo ""

# Install Tekton Pipelines
echo "🔧 [6/6] Installing Tekton Pipelines..."
"$SCRIPT_DIR/install-tekton.sh"
echo ""

echo "🎉 All operators installed successfully!"
echo ""
echo "📊 Platform Status Check:"
echo "========================"

# Check all namespaces
echo "📦 Operator Namespaces:"
kubectl get namespaces | grep -E "(cnpg-system|kafka-system|minio-operator|knative-serving|tekton-pipelines|zot-registry|cloudbox-functions)" || echo "No operator namespaces found"
echo ""

# Check all CRDs
echo "📋 Custom Resource Definitions:"
echo "PostgreSQL CRDs:"
kubectl get crd | grep postgresql || echo "No PostgreSQL CRDs found"
echo "Kafka CRDs:"
kubectl get crd | grep kafka || echo "No Kafka CRDs found"
echo "MinIO CRDs:"
kubectl get crd | grep minio || echo "No MinIO CRDs found"
echo "Knative CRDs:"
kubectl get crd | grep knative || echo "No Knative CRDs found"
echo "Tekton CRDs:"
kubectl get crd | grep tekton || echo "No Tekton CRDs found"
echo ""

echo "✅ CloudBox platform is ready!"
echo ""
echo "🔗 Next Steps:"
echo "   - Start the Go API server to manage resources"
echo "   - Access the web UI to create databases, queues, storage, and functions"
echo "   - Use 'kubectl get pods -A | grep -E \"(cnpg|kafka|minio|knative|tekton)\"' to check all operator pods"
