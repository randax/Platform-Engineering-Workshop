---
layout: center
class: text-center
---

# Lab 1: Foundation
## Setting up Talos Kubernetes

<div class="mt-8">
  <span @click="$slidev.nav.next" class="px-4 py-2 rounded cursor-pointer bg-blue-600 text-white hover:bg-blue-700">
    Let's Build! <carbon:arrow-right class="inline"/>
  </span>
</div>

<!--
Lab 1 introduces our foundation layer:
- Talos Linux as the OS
- Kubernetes as the orchestration platform
- Cilium for networking and security

This creates a solid, secure, immutable base for our platform.
-->

---

# Why Talos Linux?

<div class="grid grid-cols-2 gap-8">

<div>

## Traditional Kubernetes
```bash
# SSH into nodes
ssh user@node1

# Install Docker/containerd
apt-get install docker.io

# Configure kubelet
systemctl enable kubelet

# Security concerns
# - SSH access
# - Package managers
# - Multiple ways to break things
```

</div>

<div>

## Talos Linux
```bash
# API-driven management
talosctl cluster create

# Immutable OS
# - No SSH/shell access
# - No package manager
# - API-only configuration
# - Predictable behavior

# Fast boot (~45 seconds)
# Kubernetes-specific OS
```

</div>

</div>

<div v-click class="mt-4 p-4 bg-green-50 text-gray-800 rounded">
  **Result**: More secure, more predictable, easier to manage at scale
</div>

<!--
Traditional Kubernetes setup challenges:
- Many moving parts (OS, container runtime, kubelet)
- Multiple configuration points and failure modes
- SSH access creates security risks
- Package managers can introduce drift

Talos Linux advantages:
- Purpose-built for Kubernetes
- Immutable infrastructure principles
- API-driven everything - no SSH needed
- Fast, consistent, predictable
- Minimal attack surface
-->

---

# Lab 1 Demo: Cluster Creation

Let's see Talos in action:

````md magic-move {lines: true}
```bash
# Generate machine configuration
talosctl gen config platform-cluster https://localhost:6443
```

```bash
# Create config patch for Cilium
cat > cilium-patch.yml << 'EOF'
cluster:
  network:
    cni:
      name: none  # Disable default CNI
  proxy:
    disabled: true  # Disable kube-proxy
EOF
```

```bash
# Create multi-node cluster
talosctl cluster create \
  --name platform-cluster \
  --controlplanes 3 \
  --workers 2 \
  --config-patch @cilium-patch.yml
```

```bash
# Verify cluster
kubectl get nodes
# NAME           STATUS   ROLES           AGE
# node-1         Ready    control-plane   2m
# node-2         Ready    control-plane   2m
# node-3         Ready    control-plane   2m
# node-4         Ready    <none>          1m
# node-5         Ready    <none>          1m
```
````

<!--
Demo walkthrough:
1. Generate base configuration for our cluster
2. Create patch to disable default CNI (we'll use Cilium)
3. Create a 5-node cluster (3 control planes, 2 workers)
4. Verify everything is running

Magic move shows the progression from config to running cluster.
Key points:
- No manual OS setup
- Declarative configuration
- Fast cluster creation
- Production-ready HA setup
-->

---

# Lab 1: Your Turn! 🔨

Follow along in your terminal:

<div class="grid grid-cols-2 gap-8">

<div>

**Quick Start**
```bash
# Clone the workshop repo
git clone https://github.com/randax/\
  jz-2025-platform-engineering

cd jz-2025-platform-engineering

# Run Lab 1 setup
./scripts/dev-setup.sh
```

</div>

<div>

**What We're Building**
- 🏗️ Talos Linux cluster
- 🌐 Cilium CNI installation
- ⚙️ Basic cluster verification
- 📋 Platform readiness check

</div>

</div>

<v-click>

### Success Criteria ✅

- [ ] `kubectl get nodes` shows 5 ready nodes
- [ ] Cilium is running in `kube-system` namespace
- [ ] Basic networking tests pass
- [ ] Ready for Lab 2!

</v-click>

<!--
Hands-on time! Students follow along.

The dev-setup.sh script handles:
- Docker Desktop checks
- Talos CLI installation
- Cluster creation with Cilium
- Basic verification steps

Encourage questions and help students who run into issues.
Common problems:
- Docker not running
- Port conflicts
- Resource constraints

Success criteria ensure everyone is ready for the next lab.
-->

---

# Understanding Cilium

<v-clicks>

**Why Replace kube-proxy?**
- Traditional iptables-based networking is slow
- Limited observability and debugging
- Complex rule management at scale

**eBPF Superpowers**
- Kernel-level programmability
- High performance packet processing
- Rich networking and security features
- Deep observability

**Cilium Features**
- Load balancing without kube-proxy
- Network policies with L3-L7 filtering
- Service mesh capabilities
- Hubble for network observability

</v-clicks>

<!--
Cilium explanation for the curious:

eBPF (extended Berkeley Packet Filter) allows us to run programs in the Linux kernel without changing kernel source code or loading kernel modules.

Benefits over traditional networking:
- Performance: Direct packet processing in kernel
- Observability: Every packet can be traced
- Security: Fine-grained network policies
- Flexibility: Programmable network behavior

Cilium uses eBPF to:
- Replace kube-proxy with faster load balancing
- Implement advanced network policies
- Provide service mesh features
- Enable network observability with Hubble
-->