# CloudBox Platform - Operator Installation Scripts

This directory contains installation scripts for all the Kubernetes operators required by the CloudBox platform. These operators provide the foundation for managing databases, message queues, object storage, and serverless functions.

## Prerequisites

- Kubernetes cluster (tested with Colima)
- `kubectl` configured and connected to your cluster
- `helm` installed (for some operators)

## Quick Start

To install all operators at once:

```bash
./scripts/install-all-operators.sh
```

## Individual Operator Installation

### 1. CloudNativePG (PostgreSQL Databases)
```bash
./scripts/install-cloudnative-pg.sh
```
- **Purpose**: Manages PostgreSQL clusters and databases
- **Namespace**: `cnpg-system`
- **CRDs**: `clusters.postgresql.cnpg.io`, `poolers.postgresql.cnpg.io`

### 2. Strimzi Kafka (Message Queues)
```bash
./scripts/install-strimzi-kafka.sh
```
- **Purpose**: Manages Kafka clusters and topics
- **Namespace**: `kafka-system`
- **CRDs**: `kafkas.kafka.strimzi.io`, `kafkatopics.kafka.strimzi.io`

### 3. MinIO Operator (Object Storage)
```bash
./scripts/install-minio-operator.sh
```
- **Purpose**: Manages MinIO object storage tenants
- **Namespace**: `minio-operator`
- **CRDs**: `tenants.minio.min.io`

### 4. Knative Serving (Serverless Functions)
```bash
./scripts/install-knative-serving.sh
```
- **Purpose**: Manages serverless function deployments
- **Namespace**: `knative-serving`
- **CRDs**: `services.serving.knative.dev`, `configurations.serving.knative.dev`

## Verification

After installation, verify that all operators are running:

```bash
# Check all operator pods
kubectl get pods -A | grep -E "(cnpg|kafka|minio|knative)"

# Check installed CRDs
kubectl get crd | grep -E "(postgresql|kafka|minio|knative)"

# Check operator namespaces
kubectl get namespaces | grep -E "(cnpg-system|kafka-system|minio-operator|knative-serving)"
```

## Usage

Once the operators are installed, you can:

1. **Start the Go API server** - This will provide GraphQL APIs to manage resources
2. **Access the Web UI** - Create and manage databases, queues, storage, and functions
3. **Use kubectl directly** - Apply custom resource manifests if needed

## Troubleshooting

### Check operator logs
```bash
# CloudNativePG
kubectl logs -n cnpg-system deployment/cnpg-cloudnative-pg

# Strimzi Kafka
kubectl logs -n kafka-system deployment/strimzi-cluster-operator

# MinIO
kubectl logs -n minio-operator deployment/minio-operator

# Knative
kubectl logs -n knative-serving deployment/controller
```

### Uninstall operators
```bash
# CloudNativePG
helm uninstall cnpg -n cnpg-system

# Strimzi
helm uninstall strimzi-kafka-operator -n kafka-system

# MinIO
kubectl delete -f https://github.com/minio/operator/releases/latest/download/minio-operator.yaml

# Knative
kubectl delete -f https://github.com/knative/serving/releases/download/knative-v1.11.0/serving-core.yaml
kubectl delete -f https://github.com/knative/serving/releases/download/knative-v1.11.0/serving-crds.yaml
kubectl delete -f https://github.com/knative/net-kourier/releases/download/knative-v1.11.0/kourier.yaml
```

## Next Steps

After installing the operators:

1. **Configure the Go API server** to interact with these operators
2. **Update the GraphQL schema** to include database, queue, storage, and function management
3. **Implement controllers** in Go to create/manage resources via the operators
4. **Update the Web UI** to provide management interfaces for each service type

## Architecture

```
Web UI (Next.js)
     ↓
Go API Server (GraphQL)
     ↓
Kubernetes API
     ↓
Operators (CloudNativePG, Strimzi, MinIO, Knative)
     ↓
Managed Resources (Databases, Queues, Storage, Functions)
```
