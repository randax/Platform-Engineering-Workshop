# Lab 2: Database-as-a-Service with CloudNativePG

## Overview

In this lab, you'll learn how to provide Database-as-a-Service capabilities using CloudNativePG, a Kubernetes operator that manages PostgreSQL clusters with enterprise-grade features like high availability, automated backups, and monitoring.

## Learning Objectives

By the end of this lab, you will be able to:

- Install and configure the CloudNativePG operator
- Create and manage PostgreSQL clusters using Kubernetes manifests
- Understand operator-based database management
- Connect applications to operator-managed databases
- Monitor database health and performance
- Implement backup and recovery strategies

## Prerequisites

- Completed Lab 1 (Talos Kubernetes cluster running)
- kubectl configured and connected to your cluster
- helm installed (comes with dev-setup.sh)
- Basic understanding of PostgreSQL concepts

## Why CloudNativePG?

CloudNativePG provides:

- **Kubernetes-native**: Fully integrated with Kubernetes APIs and workflows
- **High Availability**: Automatic failover and leader election
- **Backup & Recovery**: Point-in-time recovery with barman integration
- **Monitoring**: Built-in Prometheus metrics and PostgreSQL monitoring
- **Security**: TLS encryption, RBAC integration, secret management
- **Scaling**: Read replicas and connection pooling

## Lab Steps

### Step 1: Install CloudNativePG Operator

First, let's install the CloudNativePG operator. We can use our automation script, but let's understand what it's doing:

```bash
# Option 1: Use the automation script
./scripts/install-cloudnativepg.sh
```

**What the script does:** The installation script performs the following steps:

1. **Prerequisites check:**

   ```bash
   # Verify kubectl and helm are installed
   kubectl version --client
   helm version

   # Check current Kubernetes context
   kubectl config current-context
   ```

2. **Add the CloudNativePG Helm repository:**

   ```bash
   # Add the official CloudNativePG Helm repository
   helm repo add cnpg https://cloudnative-pg.github.io/charts

   # Update Helm repositories to get latest charts
   helm repo update
   ```

3. **Install the operator using Helm:**

   ```bash
   # Install CloudNativePG operator in dedicated namespace
   helm upgrade --install cnpg \
     --namespace cnpg-system \
     --create-namespace \
     cnpg/cloudnative-pg \
     --wait
   ```

4. **Verify the installation:**

   ```bash
   # Wait for operator pod to be ready
   kubectl wait --for=condition=Ready pod \
     -l app.kubernetes.io/name=cloudnative-pg \
     -n cnpg-system --timeout=300s
   ```

**Option 2: Install manually** (step-by-step for deeper understanding):

```bash
# Step 1: Add Helm repository
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

# Step 2: Install the operator
helm upgrade --install cnpg \
  --namespace cnpg-system \
  --create-namespace \
  cnpg/cloudnative-pg \
  --wait

# Step 3: Verify installation
kubectl get pods -n cnpg-system
kubectl get crd | grep postgresql
```

This installation:

- Creates a dedicated `cnpg-system` namespace for the operator
- Installs the CloudNativePG controller and webhooks
- Registers Custom Resource Definitions (CRDs) for PostgreSQL clusters
- Sets up RBAC permissions for cluster management
- Enables the operator to watch for PostgreSQL cluster resources

### Step 2: Verify Operator Installation

Check that the operator is running correctly:

```bash
# Check operator pods
kubectl get pods -n cnpg-system

# Verify CRDs are installed
kubectl get crd | grep postgresql

# Check operator logs
kubectl logs -n cnpg-system deployment/cnpg-cloudnative-pg
```

You should see:

- The operator pod in `Running` state
- Several PostgreSQL-related CRDs installed
- No errors in the operator logs

### Step 3: Create Your First PostgreSQL Cluster

Now let's create a PostgreSQL cluster. We can use our automation script, but let's understand what it's doing by looking at the manifest it creates:

```bash
# Option 1: Use the automation script
./scripts/create-postgres-cluster.sh workshop-db default
```

**What the script does:** Let's break down what happens when you run the script above. The script creates the following Kubernetes resources:

```yaml
# PostgreSQL Cluster Definition
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: workshop-db
  namespace: default
spec:
  instances: 3  # High availability with 3 instances

  # PostgreSQL configuration parameters
  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"        # Memory for caching
      effective_cache_size: "1GB"    # Expected available memory
      wal_buffers: "16MB"            # Write-ahead log buffers
      checkpoint_completion_target: "0.9"
      random_page_cost: "1.1"        # Optimized for SSD storage
      effective_io_concurrency: "200"

  # Database initialization
  bootstrap:
    initdb:
      database: appdb               # Application database name
      owner: app                   # Database owner username
      secret:
        name: workshop-db-app-user # Secret containing credentials

  # Storage configuration
  storage:
    size: 1Gi
    storageClass: "local-path"     # Use local storage

  # Resource limits
  resources:
    requests:
      memory: "256Mi"
      cpu: "100m"
    limits:
      memory: "512Mi"
      cpu: "500m"

  # Enable Prometheus monitoring
  monitoring:
    enabled: true

  # Backup configuration (commented out - requires external storage)
  # backup:
  #   retention: "30d"
  #   barmanObjectStore:
  #     destinationPath: "s3://backup-bucket/postgres"

---
# Database credentials secret
apiVersion: v1
kind: Secret
metadata:
  name: workshop-db-app-user
  namespace: default
type: kubernetes.io/basic-auth
stringData:
  username: app
  password: [randomly-generated-password]
```

**Option 2: Create manually** (optional - for deeper understanding):

```bash
# Apply the manifest directly (you can use the file in this lab directory)
kubectl apply -f lab/02-databases/postgres-cluster.yaml
```

This creates:

- A 3-instance PostgreSQL cluster for high availability
- Application database (`appdb`) and user credentials
- Performance-tuned PostgreSQL configuration
- Monitoring and metrics collection
- Resource limits for stable operation

### Step 4: Monitor Cluster Creation

Watch the cluster come online:

```bash
# Watch cluster status
kubectl get cluster workshop-db -w

# Check all pods in the cluster
kubectl get pods -l cnpg.io/cluster=workshop-db

# View detailed cluster information
kubectl describe cluster workshop-db
```

The cluster is ready when:

- Status shows "Cluster in healthy state"
- All 3 PostgreSQL pods are running
- One pod is designated as primary (read-write)
- Two pods are replicas (read-only)

### Step 5: Connect to Your Database

Let's connect to the database and verify it's working:

```bash
# Get the database password
DB_PASSWORD=$(kubectl get secret workshop-db-app-user -o jsonpath='{.data.password}' | base64 -d)
echo "Database password: $DB_PASSWORD"

# Port forward to access the database locally
kubectl port-forward svc/workshop-db-rw 5432:5432 &

# Connect using psql (in another terminal)
PGPASSWORD=$DB_PASSWORD psql -h localhost -p 5432 -U app -d appdb
```

### Step 6: Test Database Operations

Once connected, try some basic operations:

```sql
-- Create a test table
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert some test data
INSERT INTO users (name, email) VALUES
    ('Alice Johnson', 'alice@example.com'),
    ('Bob Smith', 'bob@example.com'),
    ('Carol Davis', 'carol@example.com');

-- Query the data
SELECT * FROM users;

-- Check database info
SELECT version();
\l
\dt
\q
```

### Step 7: Explore High Availability

CloudNativePG provides automatic failover. Let's see this in action:

```bash
# Find the current primary pod
kubectl get pods -l cnpg.io/cluster=workshop-db -o wide

# Check which pod is the primary (look for rw service endpoint)
kubectl get endpoints workshop-db-rw

# Simulate a failure by deleting the primary pod
PRIMARY_POD=$(kubectl get pods -l cnpg.io/cluster=workshop-db,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
echo "Current primary: $PRIMARY_POD"
kubectl delete pod $PRIMARY_POD

# Watch the failover process
kubectl get pods -l cnpg.io/cluster=workshop-db -w
```

You should observe:

- The deleted pod being recreated
- A new primary being elected
- Services updating to point to the new primary
- Minimal downtime (usually < 30 seconds)

### Step 8: Monitor Database Metrics

CloudNativePG exposes Prometheus metrics for monitoring:

```bash
# Check if monitoring is enabled
kubectl get cluster workshop-db -o jsonpath='{.spec.monitoring.enabled}'

# View available metrics (port forward to a pod)
POD_NAME=$(kubectl get pods -l cnpg.io/cluster=workshop-db -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward $POD_NAME 9187:9187 &

# Check metrics endpoint
curl http://localhost:9187/metrics | grep cnpg
```

### Step 9: Create a Read-Only Application Connection

Applications often need separate read and write connections:

```bash
# Create a deployment that uses the read-only service
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db-reader
spec:
  replicas: 1
  selector:
    matchLabels:
      app: db-reader
  template:
    metadata:
      labels:
        app: db-reader
    spec:
      containers:
      - name: postgres-client
        image: postgres:15
        command: ["sleep", "3600"]
        env:
        - name: PGHOST
          value: "workshop-db-ro"  # Read-only service
        - name: PGPORT
          value: "5432"
        - name: PGDATABASE
          value: "appdb"
        - name: PGUSER
          value: "app"
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: workshop-db-app-user
              key: password
EOF

# Test read-only connection
kubectl exec -it deployment/db-reader -- psql -c "SELECT count(*) FROM users;"
```

## Quick Reference

### Useful Commands

```bash
# List all PostgreSQL clusters
kubectl get clusters

# Get cluster status
kubectl get cluster <cluster-name> -o yaml

# View cluster events
kubectl describe cluster <cluster-name>

# Check cluster pods
kubectl get pods -l cnpg.io/cluster=<cluster-name>

# Access database
kubectl port-forward svc/<cluster-name>-rw 5432:5432

# Get connection details
kubectl get secret <cluster-name>-app-user -o yaml

# View operator logs
kubectl logs -n cnpg-system deployment/cnpg-cloudnative-pg
```

### Connection Services

CloudNativePG creates these services automatically:

- `<cluster-name>-rw`: Read-write (primary) connection
- `<cluster-name>-ro`: Read-only (replica) connection
- `<cluster-name>-r`: Any instance connection

### Configuration Options

Key cluster specification options:

- `instances`: Number of PostgreSQL instances (1-99)
- `postgresql.parameters`: PostgreSQL configuration
- `storage.size`: Persistent volume size
- `resources`: CPU and memory limits
- `monitoring.enabled`: Enable Prometheus metrics
- `backup`: Backup configuration

## Troubleshooting

### Cluster Won't Start

```bash
# Check operator status
kubectl get pods -n cnpg-system

# Check storage class
kubectl get storageclass

# View cluster events
kubectl describe cluster <cluster-name>

# Check persistent volumes
kubectl get pv,pvc
```

### Connection Issues

```bash
# Verify service endpoints
kubectl get endpoints <cluster-name>-rw

# Check pod logs
kubectl logs <pod-name>

# Test internal connectivity
kubectl run test-pod --image=postgres:15 --rm -it -- bash
# Then inside pod: psql -h <cluster-name>-rw -U app -d appdb
```

### Performance Issues

```bash
# Check resource usage
kubectl top pods -l cnpg.io/cluster=<cluster-name>

# View PostgreSQL logs
kubectl logs <pod-name> | grep -E "(ERROR|WARNING|SLOW)"

# Check metrics
kubectl port-forward <pod-name> 9187:9187
curl localhost:9187/metrics | grep cnpg_
```

## Next Steps

In the next lab, we'll explore:

- Message queues with Strimzi Kafka
- Event-driven architectures
- Connecting databases to streaming platforms

## Additional Resources

- [CloudNativePG Documentation](https://cloudnative-pg.io/)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Kubernetes Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Database Reliability Engineering](https://www.oreilly.com/library/view/database-reliability-engineering/9781491925949/)
