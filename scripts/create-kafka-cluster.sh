#!/bin/bash

# Kafka Cluster Creation Script
set -e

CLUSTER_NAME=${1:-"kafka-cluster"}
NAMESPACE=${2:-"kafka"}

echo "📨 Creating Kafka cluster: $CLUSTER_NAME in namespace: $NAMESPACE"

# Check if Strimzi operator is installed
if ! kubectl get crd kafkas.kafka.strimzi.io &> /dev/null; then
    echo "❌ Strimzi operator not found. Please run ./scripts/install-kafka.sh first"
    exit 1
fi

# Create Kafka cluster manifest
cat <<EOF | kubectl apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: $CLUSTER_NAME
  namespace: $NAMESPACE
spec:
  kafka:
    version: 3.6.0
    replicas: 3
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2
      inter.broker.protocol.version: "3.6"
    storage:
      type: jbod
      volumes:
      - id: 0
        type: persistent-claim
        size: 2Gi
        deleteClaim: false
        class: local-path
    resources:
      requests:
        memory: 1Gi
        cpu: 100m
      limits:
        memory: 2Gi
        cpu: 500m
  zookeeper:
    replicas: 3
    storage:
      type: persistent-claim
      size: 1Gi
      deleteClaim: false
      class: local-path
    resources:
      requests:
        memory: 512Mi
        cpu: 100m
      limits:
        memory: 1Gi
        cpu: 250m
  entityOperator:
    topicOperator: {}
    userOperator: {}

---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: events
  namespace: $NAMESPACE
  labels:
    strimzi.io/cluster: $CLUSTER_NAME
spec:
  partitions: 12
  replicas: 3
  config:
    retention.ms: 604800000
    segment.ms: 86400000
    cleanup.policy: delete

---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: notifications
  namespace: $NAMESPACE
  labels:
    strimzi.io/cluster: $CLUSTER_NAME
spec:
  partitions: 6
  replicas: 3
  config:
    retention.ms: 259200000
    segment.ms: 43200000
    cleanup.policy: delete

---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: audit-logs
  namespace: $NAMESPACE
  labels:
    strimzi.io/cluster: $CLUSTER_NAME
spec:
  partitions: 3
  replicas: 3
  config:
    retention.ms: 2592000000
    segment.ms: 604800000
    cleanup.policy: delete
EOF

echo "⏳ Waiting for Kafka cluster to be ready..."
kubectl wait --for=condition=Ready kafka/$CLUSTER_NAME -n $NAMESPACE --timeout=600s

echo "📊 Cluster status:"
kubectl get kafka $CLUSTER_NAME -n $NAMESPACE
kubectl get pods -l strimzi.io/cluster=$CLUSTER_NAME -n $NAMESPACE
kubectl get kafkatopic -n $NAMESPACE

echo "🔑 Kafka connection details:"
echo "Bootstrap servers: $CLUSTER_NAME-kafka-bootstrap.$NAMESPACE.svc.cluster.local:9092"
echo "TLS Bootstrap servers: $CLUSTER_NAME-kafka-bootstrap.$NAMESPACE.svc.cluster.local:9093"

echo "🎉 Kafka cluster '$CLUSTER_NAME' created successfully!"
echo ""
echo "Connection examples:"
echo "# Port forward to access locally:"
echo "kubectl port-forward svc/$CLUSTER_NAME-kafka-bootstrap 9092:9092 -n $NAMESPACE"
echo ""
echo "# Test with kafka console tools:"
echo "kubectl run kafka-producer -ti --image=quay.io/strimzi/kafka:0.38.0-kafka-3.6.0 --rm=true --restart=Never -- bin/kafka-console-producer.sh --bootstrap-server $CLUSTER_NAME-kafka-bootstrap:9092 --topic events"
