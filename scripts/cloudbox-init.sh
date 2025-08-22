#!/bin/bash

set -euo pipefail

echo "🚀 CloudBox Platform - Initializing Core Infrastructure"
echo "======================================================="

# Create core namespace
echo "🏗️  Creating CloudBox management namespace..."

# CloudBox system namespace for platform management components
echo "� Creating cloudbox-system namespace..."
cat << 'EOF' | mise exec -- kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: cloudbox-system
  labels:
    name: cloudbox-system
    app.kubernetes.io/name: cloudbox
    app.kubernetes.io/component: system
    app.kubernetes.io/part-of: cloudbox-platform
    cloudbox.io/managed: "true"
EOF

# Create RBAC for CloudBox platform
echo "🔐 Setting up CloudBox RBAC..."

# Create CloudBox service account
cat << 'EOF' | mise exec -- kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cloudbox-controller
  namespace: cloudbox-system
  labels:
    app.kubernetes.io/name: cloudbox
    app.kubernetes.io/component: controller
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cloudbox-controller
  labels:
    app.kubernetes.io/name: cloudbox
    app.kubernetes.io/component: controller
rules:
# Core Kubernetes resources
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "secrets", "persistentvolumeclaims"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets", "replicasets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# Custom Resource Definitions
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
# PostgreSQL (CloudNativePG)
- apiGroups: ["postgresql.cnpg.io"]
  resources: ["clusters", "backups", "scheduledbackups"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# Kafka (Strimzi)
- apiGroups: ["kafka.strimzi.io"]
  resources: ["kafkas", "kafkatopics", "kafkausers"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# MinIO
- apiGroups: ["minio.min.io"]
  resources: ["tenants"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# Knative Serving
- apiGroups: ["serving.knative.dev"]
  resources: ["services", "configurations", "revisions", "routes"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# Networking
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses", "networkpolicies"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cloudbox-controller
  labels:
    app.kubernetes.io/name: cloudbox
    app.kubernetes.io/component: controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cloudbox-controller
subjects:
- kind: ServiceAccount
  name: cloudbox-controller
  namespace: cloudbox-system
EOF

# Create NetworkPolicies for cloudbox-system
echo "🔒 Setting up network policies for cloudbox-system..."

# Allow all communication for cloudbox-system management components
cat << 'EOF' | mise exec -- kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cloudbox-system-access
  namespace: cloudbox-system
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - {}  # Allow all ingress to management components
  egress:
  - to:
    - ipBlock:
        cidr: 192.168.5.1/32
    ports:
    - protocol: TCP
      port: 55059
  - to:
    - namespaceSelector: {}
  - to:
    - podSelector: {}
EOF

# Create initial ConfigMap with platform configuration
echo "⚙️  Creating platform configuration..."
cat << 'EOF' | mise exec -- kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudbox-platform-config
  namespace: cloudbox-system
  labels:
    app.kubernetes.io/name: cloudbox
    app.kubernetes.io/component: config
data:
  platform.version: "v1.0.0"
  platform.namespace: "cloudbox-system"
  registry.url: "zot-registry-internal.zot-registry:5000"
  registry.namespace: "zot-registry"
  default.user.namespace.prefix: "user-"
  management.apis.enabled: "true"
  user.resources.enabled: "true"
EOF

echo ""
echo "✅ CloudBox platform initialization completed!"
echo ""
echo "📋 Created namespace:"
echo "  • cloudbox-system      - Core platform management components"
echo ""
echo "🔐 RBAC configured:"
echo "  • cloudbox-controller service account"
echo "  • Cluster-wide permissions for managing resources"
echo "  • Network policies for management access"
echo ""
echo "📊 Platform management:"
echo "  • Platform configuration in ConfigMap"
echo "  • User resources will be created in user-* namespaces"
echo ""
echo "🔗 Next steps:"
echo "  • Install operators: mise run k8s:setup"
echo "  • Deploy API server: mise run k8s:deploy"
echo "  • Access web UI: mise run frontend:dev"
echo "  • Users will create their own namespaces for databases, storage, functions, etc."
