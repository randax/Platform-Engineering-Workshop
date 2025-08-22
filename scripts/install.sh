#!/bin/bash

set -e

echo "🚀 Installing Private Cloud Platform..."

# Check prerequisites
echo "📋 Checking prerequisites..."

if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo "❌ helm is not installed"
    exit 1
fi

# Check if Kubernetes cluster is accessible
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Kubernetes cluster is not accessible"
    exit 1
fi

echo "✅ Prerequisites check passed"

# Install required operators
echo "📦 Installing operators..."

# Install CloudNativePG for PostgreSQL
echo "Installing CloudNativePG operator..."
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.21/releases/cnpg-1.21.0.yaml

# Install Knative Serving for Functions
echo "Installing Knative Serving..."
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.12.0/serving-crds.yaml
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.12.0/serving-core.yaml

# Install Kourier as Knative networking layer
kubectl apply -f https://github.com/knative/net-kourier/releases/download/knative-v1.12.0/kourier.yaml
kubectl patch configmap/config-network \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'

# Install Cilium CNI (if not already installed)
echo "🌐 Installing Cilium CNI..."
helm repo add cilium https://helm.cilium.io/
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --set operator.replicas=1 \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true

# Install Kyverno Policy Engine
echo "🛡️  Installing Kyverno..."
helm repo add kyverno https://kyverno.github.io/kyverno/
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace

# Install monitoring stack with Tempo
echo "📊 Installing monitoring stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Install Prometheus + Grafana
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=admin123 \
  --wait

# Install Tempo for distributed tracing
helm upgrade --install tempo grafana/tempo \
  --namespace monitoring \
  --set tempo.repository=grafana/tempo \
  --set tempo.tag=latest

# Install Loki for log aggregation
helm upgrade --install loki grafana/loki-stack \
  --namespace monitoring \
  --set grafana.enabled=false \
  --set prometheus.enabled=false \
  --set promtail.enabled=true

# Install Zitadel for authentication
echo "🔐 Installing Zitadel..."
helm repo add zitadel https://charts.zitadel.com
helm upgrade --install zitadel zitadel/zitadel \
  --namespace zitadel \
  --create-namespace \
  --set zitadel.masterkeySecretName=zitadel-masterkey \
  --set zitadel.configmapConfig.ExternalSecure=false

# Install MinIO
echo "💾 Installing MinIO..."
helm repo add minio https://charts.min.io/
helm upgrade --install minio minio/minio \
  --namespace minio \
  --create-namespace \
  --set rootUser=admin \
  --set rootPassword=admin123 \
  --set mode=distributed \
  --set replicas=4 \
  --wait

# Install RedPanda
echo "📨 Installing RedPanda..."
helm repo add redpanda https://charts.redpanda.com/
helm upgrade --install redpanda redpanda/redpanda \
  --namespace redpanda \
  --create-namespace \
  --set statefulset.replicas=3 \
  --set auth.sasl.enabled=false \
  --wait

# Build and deploy the platform API
echo "🔧 Building and deploying platform API..."
docker build -t private-cloud-api:latest .
kubectl apply -f deploy/base/

# Wait for deployments
echo "⏳ Waiting for deployments to be ready..."
kubectl wait --for=condition=available deployment/cloud-api -n cloud-system --timeout=300s

echo "✅ Private Cloud Platform installed successfully!"
echo ""
echo "📖 Access Information:"
echo "  API Endpoint: http://api.cloud.local (add to /etc/hosts)"
echo "  Frontend: http://localhost:3000 (after running 'cd web && npm run dev')"
echo "  Zitadel: http://zitadel.cloud.local (admin console)"
echo "  Grafana: http://monitoring-grafana.monitoring.svc.cluster.local:80 (admin/admin123)"
echo "  MinIO Console: http://minio-console.minio.svc.cluster.local:9001 (admin/admin123)"
echo "  Hubble UI: http://hubble-ui.kube-system.svc.cluster.local:12000"
echo ""
echo "🔗 Port Forward Commands:"
echo "  API: kubectl port-forward -n cloud-system svc/cloud-api 8080:80"
echo "  Frontend: cd web && npm run dev"
echo "  Grafana: kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80"
echo "  MinIO: kubectl port-forward -n minio svc/minio-console 9001:9001"
echo "  Zitadel: kubectl port-forward -n zitadel svc/zitadel 8080:8080"
echo "  Hubble: kubectl port-forward -n kube-system svc/hubble-ui 12000:80"
echo ""
echo "🔧 Next Steps:"
echo "  1. Configure Zitadel: Create project and application"
echo "  2. Update environment variables in web/.env.local"
echo "  3. Start frontend: cd web && npm install && npm run dev"
echo "  4. Access the platform at http://localhost:3000"
echo ""
echo "Happy coding! 🎉"
