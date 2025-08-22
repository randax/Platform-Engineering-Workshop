#!/bin/bash

set -euo pipefail

echo "🔧 Installing Zot Container Registry..."

# Add zot helm repository
echo "📦 Adding Zot Helm repository..."
mise exec -- helm repo add project-zot http://zotregistry.dev/helm-charts
mise exec -- helm repo update project-zot

# Create namespace for zot
echo "🏗️  Creating zot namespace..."
mise exec -- kubectl create namespace zot-registry --dry-run=client -o yaml | mise exec -- kubectl apply -f -

# Create cloudbox-system namespace for platform components
echo "🏗️  Creating cloudbox-system namespace..."
mise exec -- kubectl create namespace cloudbox-system --dry-run=client -o yaml | mise exec -- kubectl apply -f -

# Create custom values file for zot configuration
echo "⚙️  Creating Zot configuration..."
cat > /tmp/zot-values.yaml << 'EOF'
# Custom values for zot registry
replicaCount: 1

image:
  repository: ghcr.io/project-zot/zot-linux-arm64
  pullPolicy: IfNotPresent
  tag: "v2.1.7"

service:
  type: NodePort
  port: 5000
  nodePort: 30500

# Resource limits
resources:
  requests:
    memory: "256Mi"
    cpu: "100m"
  limits:
    memory: "1Gi"
    cpu: "500m"

# Security context
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
  fsGroup: 65534

securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
  allowPrivilegeEscalation: false
  capabilities:
    drop:
    - ALL
  readOnlyRootFilesystem: false

# Enable persistence for registry data
persistence: true

# PVC configuration
pvc:
  create: true
  accessModes: ["ReadWriteOnce"]
  storage: 50Gi
  storageClassName: null

# Zot configuration - using configFiles instead of zot.configData
mountConfig: true
configFiles:
  config.json: |-
    {
      "storage": {
        "rootDirectory": "/var/lib/registry",
        "dedupe": true,
        "gc": true,
        "gcDelay": "1h",
        "gcInterval": "24h"
      },
      "http": {
        "address": "0.0.0.0",
        "port": "5000"
      },
      "log": {
        "level": "info",
        "output": "/dev/stdout"
      },
      "extensions": {
        "metrics": {
          "enable": true,
          "prometheus": {
            "path": "/metrics"
          }
        },
        "search": {
          "enable": true,
          "cve": {
            "updateInterval": "24h"
          }
        },
        "ui": {
          "enable": true
        }
      }
    }

# Enable metrics
metrics:
  enabled: true
  serviceMonitor:
    enabled: false

# Ingress configuration
ingress:
  enabled: false
  className: ""
  annotations: {}
  hosts:
    - host: zot.local
      paths:
        - path: /
  tls: []

# Health check configuration
httpGet:
  scheme: HTTP
  port: 5000

# Startup probe for better initialization
startupProbe:
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 6
EOF

# Install zot using helm
echo "🚀 Installing Zot registry..."
mise exec -- helm upgrade --install zot project-zot/zot \
  --namespace zot-registry \
  --values /tmp/zot-values.yaml \
  --wait \
  --timeout 10m

# Wait for zot to be ready
echo "⏳ Waiting for Zot registry to be ready..."
mise exec -- kubectl wait --namespace zot-registry \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=zot \
  --timeout=300s

# Create a service for internal cluster access
echo "🔗 Creating internal service for Zot..."
cat << 'EOF' | mise exec -- kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: zot-registry-internal
  namespace: zot-registry
  labels:
    app: zot-internal
spec:
  type: ClusterIP
  ports:
    - port: 5000
      targetPort: 5000
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/name: zot
EOF

# Create NetworkPolicy to allow access from build namespace
echo "🔒 Creating NetworkPolicy for Zot access..."
cat << 'EOF' | mise exec -- kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: zot-registry-access
  namespace: zot-registry
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: zot
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: cloudbox-functions
    - namespaceSelector:
        matchLabels:
          name: cloudbox-system
    ports:
    - protocol: TCP
      port: 5000
  - from: []  # Allow all ingress traffic for now
    ports:
    - protocol: TCP
      port: 5000
EOF

# Create secret for registry authentication (optional)
echo "🔐 Creating registry authentication secret..."
mise exec -- kubectl create secret generic zot-registry-auth \
  --namespace=cloudbox-system \
  --from-literal=username=admin \
  --from-literal=password=$(openssl rand -base64 32) \
  --dry-run=client -o yaml | mise exec -- kubectl apply -f -

# Test registry connectivity
echo "🧪 Testing Zot registry connectivity..."
mise exec -- kubectl run test-zot --rm -i --restart=Never --image=curlimages/curl -- \
  curl -f http://zot-registry-internal.zot-registry:5000/v2/_catalog || {
  echo "❌ Failed to connect to Zot registry"
  exit 1
}

# Port forward for local access (optional)
echo "🌐 Setting up port forwarding for local access..."
echo "You can access Zot registry locally at:"
echo "  Registry API: mise exec -- kubectl port-forward -n zot-registry svc/zot 5000:5000"
echo "  Web UI: mise exec -- kubectl port-forward -n zot-registry svc/zot 5000:5000 then visit http://localhost:5000"

# Create configmap with registry configuration for other services
echo "📝 Creating Zot registry configuration ConfigMap..."
cat << 'EOF' | mise exec -- kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: zot-registry-config
  namespace: cloudbox-system
data:
  registry.url: "localhost:30500"
  registry.internal.url: "zot-registry-internal.zot-registry:5000"
  registry.nodeport.url: "localhost:30500"
  registry.namespace: "zot-registry"
  registry.service: "zot-registry-internal"
  registry.ui.url: "http://localhost:30500"
EOF

# Clean up temporary files
rm -f /tmp/zot-values.yaml

echo "✅ Zot Container Registry installation completed!"
echo ""
echo "📊 Registry Information:"
echo "  Internal URL: zot-registry-internal.zot-registry:5000 (cluster only)"
echo "  NodePort URL: localhost:30500 (for image pulls)"
echo "  External URL: http://localhost:30500 (if port forwarding is active)"
echo "  Web UI: Available at http://localhost:30500"
echo "  Metrics: Available at /metrics endpoint"
echo ""
echo "🔧 Next steps:"
echo "  1. Use localhost:30500 for Docker/containerd image operations"
echo "  2. Configure Tekton to push to localhost:30500"
echo "  3. Configure Knative to pull from localhost:30500"
echo ""
echo "💡 Useful commands:"
echo "  Check status: mise exec -- kubectl get pods -n zot-registry"
echo "  View logs: mise exec -- kubectl logs -n zot-registry -l app.kubernetes.io/name=zot"
echo "  Test registry: curl http://localhost:30500/v2/_catalog"
