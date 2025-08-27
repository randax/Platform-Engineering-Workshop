---
layout: center
class: text-center
---

# Lab 2: Database Platform
## CloudNativePG in Action

<div class="mt-8">
  <span @click="$slidev.nav.next" class="px-4 py-2 rounded cursor-pointer bg-purple-600 text-white hover:bg-purple-700">
    Build Data Platform! <carbon:data-base class="inline"/>
  </span>
</div>

<!--
Lab 2 focuses on building a production-ready database platform:
- PostgreSQL with automatic high availability
- Backup and recovery capabilities
- Monitoring and observability
- Self-service database provisioning

This demonstrates how operators enable platform capabilities.
-->

---

# Why CloudNativePG?

<v-clicks>

**Traditional Database Setup**
- Manual installation and configuration
- Custom backup scripts
- Manual failover procedures
- Snowflake servers

**CloudNativePG Operator**
- Kubernetes-native PostgreSQL
- Automatic backup and recovery
- Built-in high availability
- Declarative configuration
- Production-grade monitoring

</v-clicks>

<div v-click="6" class="mt-6 grid grid-cols-3 gap-4 text-center">
  <div class="p-4 bg-blue-50 text-gray-800 rounded">
    <div class="text-xl">⚡</div>
    <div class="text-sm text-gray-700">Auto Failover</div>
  </div>
  <div class="p-4 bg-green-50 text-gray-800 rounded">
    <div class="text-xl">📊</div>
    <div class="text-sm text-gray-700">Built-in Monitoring</div>
  </div>
  <div class="p-4 bg-purple-50 text-gray-800 rounded">
    <div class="text-xl">🔄</div>
    <div class="text-sm text-gray-700">Point-in-Time Recovery</div>
  </div>
</div>

<!--
Traditional database challenges:
- Manual setup is error-prone and time-consuming
- Backup strategies often untested until disaster strikes
- Failover requires human intervention and downtime
- Each database becomes a unique snowflake

CloudNativePG solves these problems by:
- Automating the entire PostgreSQL lifecycle
- Providing consistent, tested backup/recovery
- Enabling automatic failover with zero data loss
- Using Kubernetes declarative principles
- Including comprehensive monitoring out of the box
-->

---

# Lab 2 Demo: PostgreSQL Cluster

Let's create a production-ready database:

````md magic-move {lines: true}
```bash
# Install the operator
helm upgrade --install cnpg \
  --namespace cnpg-system \
  --create-namespace \
  cnpg/cloudnative-pg
```

```yaml
# PostgreSQL Cluster Definition
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: workshop-db
spec:
  instances: 3  # High availability

  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"
```

```yaml
# Complete cluster with monitoring
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: workshop-db
spec:
  instances: 3

  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"

  bootstrap:
    initdb:
      database: appdb
      owner: app
      secret:
        name: app-secret

  monitoring:
    enabled: true
```

```bash
# Verify the cluster
kubectl get clusters
# NAME          AGE   INSTANCES   READY   STATUS
# workshop-db   2m    3           3       Cluster in healthy state

kubectl get pods
# NAME            READY   STATUS    RESTARTS   AGE
# workshop-db-1   1/1     Running   0          2m
# workshop-db-2   1/1     Running   0          1m
# workshop-db-3   1/1     Running   0          1m
```
````

<!--
Demo progression:
1. Install the CloudNativePG operator via Helm
2. Show basic cluster definition - minimal config
3. Add monitoring and database initialization
4. Verify the cluster is running and healthy

Key concepts:
- Operator pattern: install once, use many times
- Declarative configuration: describe desired state
- Automatic HA: 3 instances with automatic failover
- Built-in monitoring: Prometheus metrics included
- Secret management: credentials handled securely
-->

---

# Lab 2: Hands-On Database Platform 🔨

<div class="grid grid-cols-2 gap-8">

<div>

**Lab 2 Tasks**

```bash
# Install CloudNativePG operator
./scripts/install-cloudnativepg.sh

# Create PostgreSQL cluster
./scripts/create-postgres-cluster.sh

# Test database connectivity
kubectl get secret workshop-db-app \
  -o jsonpath='{.data.password}' | base64 -d
```

</div>

<div>

**Database Operations**

```sql
-- Connect to the database
\c appdb

-- Create application table
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert test data
INSERT INTO users (name, email) VALUES
    ('Alice Johnson', 'alice@example.com'),
    ('Bob Smith', 'bob@example.com');
```

</div>

</div>

<!--
Hands-on time! Students create their own database platform.

The scripts handle:
- Operator installation and verification
- Cluster creation with proper configuration
- Secret generation and management
- Connectivity testing

SQL operations demonstrate:
- Standard PostgreSQL functionality
- Application schema creation
- Data manipulation
- Everything works as expected

Encourage students to explore:
- Cluster status and events
- Pod logs and metrics
- Failover testing (optional)
-->

---

# Understanding Database High Availability

<v-clicks>

**Automatic Failover**
- Primary/standby architecture
- Synchronous replication
- Health monitoring and detection
- Automatic leader election

**Backup and Recovery**
- Continuous WAL archiving
- Point-in-time recovery (PITR)
- Automated backup scheduling
- Cross-region backup support

**Monitoring Integration**
- Prometheus metrics export
- Grafana dashboard templates
- Alert rules for common issues
- Performance monitoring

</v-clicks>

<!--
Deep dive into CloudNativePG capabilities:

High Availability:
- Uses PostgreSQL streaming replication
- Automatic detection of primary failure
- Promotes standby to primary automatically
- No data loss with synchronous replication

Backup Strategy:
- Continuous WAL (Write-Ahead Log) archiving
- Can restore to any point in time
- Supports multiple storage backends
- Automated retention policies

Monitoring:
- Exports PostgreSQL metrics to Prometheus
- Includes connection stats, query performance
- Pre-built Grafana dashboards available
- Integration with alerting systems

This is production-grade database management!
-->

---

# Lab 2 Results: What We Built

<div class="grid grid-cols-2 gap-8">

<div>

**Database Infrastructure**
- 🐘 3-node PostgreSQL cluster
- ⚡ Automatic failover capability
- 🔄 Continuous backup system
- 📊 Built-in monitoring metrics
- 🔒 Secure credential management

</div>

<div>

**Platform Capabilities**
- 🛠️ Self-service database provisioning
- 📈 Production-ready configuration
- 🔍 Observability and alerting
- 🏗️ Infrastructure as Code
- ♻️ Repeatable deployment patterns

</div>

</div>

<div v-click class="mt-4 p-4 bg-blue-50 text-gray-800 rounded">
  **Result**: Production-ready PostgreSQL with zero manual database administration
</div>

<!--
Recap what students have accomplished:

Technical Achievement:
- Working HA PostgreSQL cluster
- Automated operational tasks
- Production-grade configuration
- Monitoring and alerting ready

Platform Achievement:
- Reusable patterns established
- Self-service capabilities enabled
- Infrastructure automation
- Foundation for application development

This demonstrates the power of the operator pattern and Kubernetes-native tools.
Students now have a database platform they could use in production!
-->