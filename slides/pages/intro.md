# Cloud on Your Terms
## Building Your Own Cloud-Native Platform

**JavaZone 2025 Workshop**

<div class="pt-12">
  <span @click="$slidev.nav.next" class="px-2 py-1 rounded cursor-pointer bg-blue-600 text-white hover:bg-blue-700">
    Start Building! <carbon:arrow-right class="inline"/>
  </span>
</div>

<div class="abs-br m-6 flex gap-2">
  <div class="text-sm opacity-50">
    Øyvind Randa • Hans Kristian Flaatten
  </div>
</div>

---
layout: intro
---

# Welcome Platform Engineers! 👋

<div class="leading-8 opacity-80">
In the next 4 hours, we'll build a complete cloud-native platform from scratch.<br>
No vendor lock-in. No surprises. Just pure CNCF power.
</div>

<div class="my-10 grid grid-cols-3 gap-4 text-center">
  <div>
    <div class="text-2xl">🏗️</div>
    <div class="text-sm">Platform Engineering</div>
  </div>
  <div>
    <div class="text-2xl">🐘</div>
    <div class="text-sm">Database-as-a-Service</div>
  </div>
  <div>
    <div class="text-2xl">📨</div>
    <div class="text-sm">Event Streaming</div>
  </div>
</div>

<div v-click class="abs-br m-6 p-4 bg-blue-50 text-gray-800 rounded">
  <div class="text-sm font-bold">Prerequisites ✅</div>
  <div class="text-xs opacity-80">Modern laptop • Docker • Enthusiasm</div>
</div>

<!--
Welcome everyone to the workshop! Set expectations:
- 4 hours intensive hands-on
- Build real platform components
- No PowerPoint theory - we code

Check if everyone has prerequisites ready:
- Docker running
- kubectl available
- Terminal access
-->

---

# The Challenge We're Solving

<v-clicks>

- **Developers** want to focus on business logic, not infrastructure
- **Operations** teams are overwhelmed with manual tasks
- **Companies** need faster delivery without compromising reliability
- **Traditional approaches** create silos and bottlenecks

</v-clicks>

<div v-click="5" class="mt-8 p-4 bg-orange-50 text-gray-800 rounded-lg border-l-4 border-orange-400">
  <div class="font-bold text-gray-800">💡 Solution</div>
  <div class="text-sm opacity-80 text-gray-700">
    Build your own cloud-native platform using battle-tested CNCF tools
  </div>
</div>

<!--
The modern challenge is balancing developer velocity with operational excellence.
Teams are caught between:
- Speed vs Safety
- Autonomy vs Control
- Innovation vs Stability

Platform Engineering provides the answer by creating a foundation that enables both.
-->

---
layout: two-cols
---

# Our Technology Stack

<v-clicks>

**Foundation**
- 🏗️ **Kubernetes (Talos)** - Immutable OS, API-driven
- 🌐 **Cilium** - eBPF networking and security

**Data Platform**
- 🐘 **CloudNativePG** - PostgreSQL operator
- 📨 **Strimzi** - Apache Kafka on Kubernetes
- 🗃️ **MinIO** - S3-compatible object storage

**Platform Services**
- 🚀 **ArgoCD** - GitOps delivery
- ⚙️ **Crossplane** - Infrastructure as Code
- 🎭 **Backstage** - Developer portal

</v-clicks>

::right::

<div v-click="8" class="mt-4">

```mermaid {theme: 'dark', scale: 0.8}
graph TB
    DEV[👩‍💻 Developers] --> BACKSTAGE[🎭 Backstage Portal]
    BACKSTAGE --> ARGOCD[🚀 ArgoCD]
    ARGOCD --> K8S[☸️ Kubernetes]

    K8S --> DB[🐘 PostgreSQL]
    K8S --> KAFKA[📨 Kafka]
    K8S --> MINIO[🗃️ MinIO]

    K8S --> CROSSPLANE[⚙️ Crossplane]
    CROSSPLANE --> CLOUD[☁️ Cloud Resources]

    style BACKSTAGE fill:#1e40af
    style ARGOCD fill:#059669
    style K8S fill:#dc2626
```

</div>

<!--
This is our complete technology stack:

Foundation Layer:
- Talos Linux gives us an immutable, secure, API-driven Kubernetes platform
- Cilium provides advanced networking with eBPF

Data Layer:
- CloudNativePG for managed PostgreSQL
- Strimzi for Apache Kafka event streaming
- MinIO for object storage needs

Platform Layer:
- ArgoCD for GitOps-based deployments
- Crossplane for infrastructure provisioning
- Backstage as the developer portal

Each tool is battle-tested, production-ready, and follows cloud-native principles.
-->