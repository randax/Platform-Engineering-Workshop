# Lab 1: Talos Kubernetes Setup

## Overview

In this lab, you'll learn how to set up a production-ready Kubernetes cluster using Talos Linux - an immutable, API-driven operating system designed specifically for Kubernetes.

## Learning Objectives

By the end of this lab, you will be able to:
- Understand the benefits of using Talos Linux for Kubernetes
- Deploy a local Talos cluster using Docker
- Access and manage the cluster using talosctl
- Understand Talos configuration and machine concepts
- Deploy a multi-node cluster

## Prerequisites

- Docker Desktop running or other docker compatible backend
- talosctl installed (verified in setup)
- kubectl installed
- 8GB free RAM minimum

## Why Talos Linux?

Talos Linux provides:
- **Immutable OS**: No SSH, no shell - managed entirely through APIs
- **Secure by default**: Minimal attack surface, hardened kernel
- **Declarative configuration**: GitOps-friendly from the ground up
- **Purpose-built**: Designed specifically for Kubernetes
- **Fast boot times**: Typically under 45 seconds to ready

## Labs

### Deploy a cluster
1. Multi-node cluster configuration
2. High availability setup
3. Resource customization

### Step 1: Generate Machine Configuration

First, generate the Talos machine configuration:

```bash
# Create a directory for configurations
mkdir -p talos-config
cd talos-config

# Generate configuration for a local cluster
talosctl gen config platform-cluster https://localhost:6443 \
  --output-dir .
```

This creates:
- `controlplane.yaml`: Control plane node configuration
- `worker.yaml`: Worker node configuration
- `talosconfig`: Client configuration for talosctl

### Step 2: Creating a multinode Talos Cluster

We are using cilium for the lab so we need to disable CNI and kube proxy with a config patch.

```bash
cat > cilium-patch.yml << 'EOF'
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
EOF
```


```bash
# Clean up existing cluster
talosctl cluster destroy --name platform-cluster

# Create multi-node cluster
talosctl cluster create \
  --name platform-cluster \
  --controlplanes 3 \
  --workers 2 \
  --endpoints 127.0.0.1 \
  --kubernetes-version 1.33.4 \
  --config-patch @cilium-patch.yml \
  --skip-k8s-node-readiness-check
```
### Step 3: Configure Access

Once the cluster is created:

```bash
# Merge the kubeconfig
talosctl kubeconfig --nodes 127.0.0.1

# Verify access
kubectl get nodes
kubectl get pods -A
```

### Step 4: Explore Talos

```bash
# Check cluster health
talosctl health --nodes 127.0.0.1

# View services
talosctl services --nodes 127.0.0.1

# Check logs
talosctl logs kubernetes --nodes 127.0.0.1

# View configuration
talosctl get machineconfig --nodes 127.0.0.1
```

## Troubleshooting 

### Talosctl can't connect docker socket 

If you are using Docker Desktop on a macOS computer, if you encounter the error: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running? you may need to manually create the link for the Docker socket:

```bash
sudo ln -s "$HOME/.docker/run/docker.sock" /var/run/docker.sock
```

### Cluster stuck in creating. 

Delete the cluster and start over

```bash
talosctl cluster destroy --name platform-cluster
```


