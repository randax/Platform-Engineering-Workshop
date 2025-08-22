# CloudNativePG Quick Reference

## Essential Commands

### Cluster Management
```bash
# List all PostgreSQL clusters
kubectl get clusters

# Get detailed cluster status
kubectl get cluster <cluster-name> -o yaml

# Describe cluster (shows events)
kubectl describe cluster <cluster-name>

# Delete a cluster
kubectl delete cluster <cluster-name>
```

### Pod and Service Information
```bash
# List cluster pods
kubectl get pods -l cnpg.io/cluster=<cluster-name>

# Check which pod is primary
kubectl get pods -l cnpg.io/cluster=<cluster-name>,cnpg.io/instanceRole=primary

# List services for a cluster
kubectl get svc -l cnpg.io/cluster=<cluster-name>

# Get service endpoints
kubectl get endpoints <cluster-name>-rw
```

### Database Connection
```bash
# Get database password
kubectl get secret <cluster-name>-app-user -o jsonpath='{.data.password}' | base64 -d

# Port forward to database
kubectl port-forward svc/<cluster-name>-rw 5432:5432

# Connect with psql
PGPASSWORD=$(kubectl get secret <cluster-name>-app-user -o jsonpath='{.data.password}' | base64 -d) \
psql -h localhost -p 5432 -U app -d appdb
```

### Monitoring and Logs
```bash
# View PostgreSQL logs
kubectl logs <pod-name>

# View operator logs
kubectl logs -n cnpg-system deployment/cnpg-cloudnative-pg

# Check metrics endpoint (requires port-forward)
kubectl port-forward <pod-name> 9187:9187
curl localhost:9187/metrics
```

## Service Types

| Service        | Purpose              | Usage                 |
| -------------- | -------------------- | --------------------- |
| `<cluster>-rw` | Read-Write (Primary) | Application writes    |
| `<cluster>-ro` | Read-Only (Replicas) | Application reads     |
| `<cluster>-r`  | Any Instance         | Maintenance/debugging |

## Common Configuration Patterns

### Basic Cluster
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: simple-cluster
spec:
  instances: 1
  storage:
    size: 1Gi
```

### High Availability Cluster
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ha-cluster
spec:
  instances: 3
  storage:
    size: 10Gi
    storageClass: fast-ssd

  resources:
    requests:
      memory: "1Gi"
      cpu: "500m"
    limits:
      memory: "2Gi"
      cpu: "1"

  monitoring:
    enabled: true
```

### Cluster with Custom Database
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: custom-db-cluster
spec:
  instances: 2

  bootstrap:
    initdb:
      database: myapp
      owner: myuser
      secret:
        name: myapp-credentials

  storage:
    size: 5Gi
```

## Troubleshooting

### Cluster Won't Start
1. Check storage class exists: `kubectl get storageclass`
2. Verify operator is running: `kubectl get pods -n cnpg-system`
3. Check events: `kubectl describe cluster <name>`
4. Review operator logs: `kubectl logs -n cnpg-system deployment/cnpg-cloudnative-pg`

### Connection Issues
1. Verify services: `kubectl get svc -l cnpg.io/cluster=<name>`
2. Check pod status: `kubectl get pods -l cnpg.io/cluster=<name>`
3. Test internal DNS: `nslookup <cluster>-rw.default.svc.cluster.local`

### Performance Issues
1. Check resource usage: `kubectl top pods -l cnpg.io/cluster=<name>`
2. Review PostgreSQL logs: `kubectl logs <pod-name>`
3. Monitor metrics: Access prometheus endpoint on port 9187

## PostgreSQL Configuration Examples

### Memory Settings
```yaml
spec:
  postgresql:
    parameters:
      shared_buffers: "256MB"        # 25% of RAM
      effective_cache_size: "1GB"    # 75% of RAM
      work_mem: "4MB"                # For sorting/joins
      maintenance_work_mem: "64MB"   # For maintenance operations
```

### Connection Settings
```yaml
spec:
  postgresql:
    parameters:
      max_connections: "100"
      superuser_reserved_connections: "3"
      idle_in_transaction_session_timeout: "60s"
```

### Performance Tuning
```yaml
spec:
  postgresql:
    parameters:
      random_page_cost: "1.1"         # For SSD storage
      effective_io_concurrency: "200" # For SSD storage
      checkpoint_completion_target: "0.9"
      wal_buffers: "16MB"
      default_statistics_target: "100"
```