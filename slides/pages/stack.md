---
layout: section
---

# The stack — and *why*

Every box was a choice. Here's what we rejected, and the tradeoff we took.

<!--
This is the "experienced-engineer tax": the audience will not accept a shopping list without the reasoning behind it. Six fast slides, one per layer, each naming what we run, what we turned down, and the one-line tradeoff. Keep it moving — it's a menu with opinions, not a spec review. ~6–8 minutes total; skip to the layers people ask about if you're tight on time.

Ground rule to state once, up front: nothing here is "best in class" in the abstract. Every pick is optimised for the same three constraints — fits a 16 GB laptop, runs fully offline, and is legible enough to read in a 4-hour workshop. A different set of constraints would give a different stack, and that's the real lesson.
-->

---

# Layer 1 — the metal & the network

<div class="stack">

| Role | We run | Rejected | The tradeoff |
|---|---|---|---|
| K8s OS | **Talos v1.13.6** | kubeadm · minikube · kind | No shell, no SSH, no drift — you lose the escape hatch on purpose |
| CNI + proxy | **Cilium 1.19.5** | flannel + kube-proxy | eBPF datapath, kube-proxy-free — needs kernel ≥5.10 |

</div>

<div class="mt-5 text-sm opacity-80">

- **Talos** is one `machineconfig` document managed over a gRPC API — the node *is* a declarative resource. kind stays in the repo as the strictly-more-robust fallback; it's a mutable node you can shell into, which is exactly what Talos refuses to be.
- **Cilium** replaces kube-proxy entirely: no growing pile of iptables rules, identity-based policy, `kubeProxyReplacement` via KubePrism on `:7445`. Service traffic is answered by eBPF programs in-kernel — there is no kube-proxy pod to find.

</div>

<style>
.stack table { font-size: 0.74rem; width: 100%; border-collapse: collapse; }
.stack th { text-align: left; font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.05em; opacity: 0.65; padding: 0.3rem 0.6rem; }
.stack td { padding: 0.35rem 0.6rem; border-top: 1px solid rgba(148,163,184,0.25); vertical-align: top; }
.stack td:nth-child(2) { color: var(--jz-run); font-weight: 700; }
.stack td:nth-child(3) { color: var(--jz-rent); }
</style>

<!--
Talos is the biggest identity shift of the day (module 01 goes deep). The pin matters: v1.13.6, never 1.12.x — cni:none docker clusters hung on readiness until the v1.13.0 fix (talos#12885). Default node memory limit is 2048 MB and the stack won't fit, so the scripts raise it (4096 CP / 6144 worker).

Cilium tradeoff to name honestly: eBPF wants a modern kernel — Docker Desktop macOS ships 6.10, WSL2 6.6, both fine; the risk platform is exotic Linux firewalld/nftables setups. We keep kube-proxy-free for the wow factor but the fallback keeps kube-proxy to remove a nested-cgroup variable — robustness vs. wow is a real dial here.
-->

---

# Layer 2 — how everything ships

<div class="stack">

| Role | We run | Rejected | The tradeoff |
|---|---|---|---|
| Git server | **Gitea 1.26.1** (in-cluster) | external GitHub | One more pod, but the write-path is offline and *yours* |
| GitOps engine | **ArgoCD v3.4.5** (app-of-apps) | Flux · manual kubectl | Drift detection + self-heal; app-of-apps is one-cluster, not fleet |

</div>

<div class="mt-5 text-sm opacity-80">

- **Gitea in the cluster**, not GitHub: attendees can't push to our GitHub, and ~50 clusters polling anonymously through one venue NAT hit GitHub's per-IP limits. Single-pod SQLite, push-to-create, seeded by a Job. ArgoCD points *only* here — the whole loop is edit → push → converge, and it never touches the internet.
- **ArgoCD app-of-apps + sync waves** over Flux (more controllers, less legible to teach) or raw `kubectl` (no reconciliation). Plain `install.yaml` with server-side apply beats Helm for teaching. The most-missed step: restore the `Application` health check in `argocd-cm`, or the waves don't gate.

</div>

<style>
.stack table { font-size: 0.74rem; width: 100%; border-collapse: collapse; }
.stack th { text-align: left; font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.05em; opacity: 0.65; padding: 0.3rem 0.6rem; }
.stack td { padding: 0.35rem 0.6rem; border-top: 1px solid rgba(148,163,184,0.25); vertical-align: top; }
.stack td:nth-child(2) { color: var(--jz-run); font-weight: 700; }
.stack td:nth-child(3) { color: var(--jz-rent); }
</style>

<!--
The Git topology is the single most important architectural decision in the workshop — it's what makes the whole thing work at a venue with hostile WiFi. This replicates the CNOE idpbuilder pattern; idpbuilder itself is kind-only (issue #74) so we copy the pattern and its manifests, not the binary.

ApplicationSets vs app-of-apps: ApplicationSets are for stamping many clusters; we have one cluster with disparate components, which is exactly the app-of-apps shape. Crossplane's CRDs blow the 262KB client-side annotation limit, so CRD-heavy apps get ServerSideApply=true; CR-shipping apps get SkipDryRunOnMissingResource=true.
-->

---

# Layer 3 — the data services

<div class="stack">

| Role | We run | Rejected | The tradeoff |
|---|---|---|---|
| Managed Postgres | **CloudNativePG 1.28.4** | bitnami/stock PG · RDS | A real control loop (failover, backup) vs. a bare pod — costs CRDs |
| Object storage (S3) | **RustFS 1.0.0-beta.8** | MinIO | Apache-2.0, ~90 MB — but young; SeaweedFS is the rehearsed Plan B |
| OCI registry | **Zot v2.1.18** | Harbor · registry:2 | One CNCF binary + UI vs. a Postgres/Redis/Trivy fleet — fewer features |
| Storage class | **local-path v0.0.36** | Longhorn · Ceph CSI | Node-local, no snapshots/replication — right for one node |

</div>

<div class="mt-5 text-sm opacity-80">

**CloudNativePG** *is* the RDS control loop, in your cluster: a `Cluster` CR reconciles into a primary + replica with backups and failover — bitnami's chart is just a Postgres pod. **RustFS** over MinIO because MinIO's community edition was gutted through 2025–26 in favour of proprietary AIStor — the exact roadmap risk this workshop is about (it's *not* a MinIO "successor"; it's an independent Apache-2.0 rewrite).

</div>

<style>
.stack table { font-size: 0.72rem; width: 100%; border-collapse: collapse; }
.stack th { text-align: left; font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.05em; opacity: 0.65; padding: 0.28rem 0.6rem; }
.stack td { padding: 0.3rem 0.6rem; border-top: 1px solid rgba(148,163,184,0.25); vertical-align: top; }
.stack td:nth-child(2) { color: var(--jz-run); font-weight: 700; }
.stack td:nth-child(3) { color: var(--jz-rent); }
</style>

<!--
CloudNativePG uses Postgres 18.4; the CRDs are far past the 262KB annotation limit so the ArgoCD app is ServerSideApply=true.

RustFS honesty: standalone mode (the chart defaults to a 4-pod distributed cluster!), ~90 MB idle, presigned GET/PUT work, presigned POST doesn't, IAM is console-first, security history is rough (that's teachable material). Switch triggers to SeaweedFS are written down for mid-August. Zot: anonymous read/write on purpose (workshop-grade), search + UI extensions on for a visible win at :30500. Harbor would be the right enterprise pick and the wrong workshop pick — Postgres, Redis, Trivy, ChartMuseum, many pods.
-->

---

# Layer 4 — self-service & compute

<div class="stack">

| Role | We run | Rejected | The tradeoff |
|---|---|---|---|
| Self-service API | **Crossplane v2.3.3** | Helm/operators · Crossplane v1 | Namespaced XRs compose real K8s resources — needs per-group RBAC |
| Serverless | **Knative v1.22** | plain Deployments · KEDA | Scale-to-zero + request buffering — an activator in the path |
| In-cluster CI | **Argo Workflows v4.0.7 + BuildKit** | Tekton · external CI | Rootless image builds, no cloud — needs a PSA-privileged namespace |

</div>

<div class="mt-5 text-sm opacity-80">

**Crossplane v2** is why self-service is one YAML: Claims are gone, you create a **namespaced XR directly**, and pipeline compositions emit arbitrary K8s resources — the composition literally composes a CNPG `Cluster`. **Knative** gives scale-to-zero (it's what Cloud Run is built on); plain Deployments are always-on and KEDA won't buffer the first request. **BuildKit** because Kaniko was archived June 2025 — rootless, pushes to your own Zot, fully in-cluster.

</div>

<style>
.stack table { font-size: 0.73rem; width: 100%; border-collapse: collapse; }
.stack th { text-align: left; font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.05em; opacity: 0.65; padding: 0.3rem 0.6rem; }
.stack td { padding: 0.33rem 0.6rem; border-top: 1px solid rgba(148,163,184,0.25); vertical-align: top; }
.stack td:nth-child(2) { color: var(--jz-run); font-weight: 700; }
.stack td:nth-child(3) { color: var(--jz-rent); }
</style>

<!--
Crossplane v2: the v1 tutorials (Claims, provider-kubernetes Object-wrapping) are actively misleading now — one slide in module 04 warns about this. v2 needs an aggregated ClusterRole per composed third-party API group because it composes resources directly; budget ~0.7–1 GiB. The Function package is fetched straight from the registry (not the node image cache), so enable Crossplane while internet is available or mirror the xpkg into Zot.

Knative: Kourier ingress (not Gateway API — not in Cilium's conformance matrix), requests halved via the k0s-blog pattern → ~0.6 GiB. BuildKit rootless needs seccomp/AppArmor Unconfined, which Talos's default PSA baseline forbids — so the build namespace is labelled pod-security.kubernetes.io/enforce=privileged. Unrehearsed combo; spiked early.
-->

---

# Layer 5 — messaging & observability

<div class="stack">

| Role | We run | Rejected | The tradeoff |
|---|---|---|---|
| Durable messaging | **NATS 2.12 + JetStream** | Kafka · RabbitMQ | The durable primitive in ~15 MB of Go vs. GBs of JVM/Erlang |
| Observability | **Victoria stack + OTel Collector** | kube-prometheus-stack · otel-lgtm · LGTM | Assembled from parts — but ~1 GiB, not several, and it fits |

</div>

<div class="mt-5 text-sm opacity-80">

**NATS JetStream** gives durable streams on a PVC for a rounding error of Kafka's RAM. The observability layer is the sharpest tradeoff: **OTel Collector** (agent DaemonSet + gateway) feeding **VictoriaMetrics** (PromQL), **VictoriaLogs** (Loki API) and **VictoriaTraces** (Jaeger API), fronted by **Grafana** with *built-in* datasources — no plugins to fetch, so it stays offline. VM's columnar TSDB + `vmrange` histograms hold the whole thing to **~1 GiB** where kube-prometheus-stack or a full Grafana LGTM would want several — and unlike single-pod otel-lgtm, there's a *real* collector, so more than three apps actually emit telemetry.

</div>

<style>
.stack table { font-size: 0.73rem; width: 100%; border-collapse: collapse; }
.stack th { text-align: left; font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.05em; opacity: 0.65; padding: 0.3rem 0.6rem; }
.stack td { padding: 0.33rem 0.6rem; border-top: 1px solid rgba(148,163,184,0.25); vertical-align: top; }
.stack td:nth-child(2) { color: var(--jz-run); font-weight: 700; }
.stack td:nth-child(3) { color: var(--jz-rent); }
</style>

<!--
Pins: NATS 2.12.12; VictoriaMetrics 1.147.0, VictoriaLogs 1.24.0, VictoriaTraces 0.9.4, Grafana 12.4.5, OTel Collector contrib 0.149.0. Observability is on-demand — enabled from the catalog as the module-09 capstone "now observe what you built", not part of the wave-0 baseline.

The four things we rejected, precisely: kube-prometheus-stack (heavy, and no traces at all); single-pod otel-lgtm (no real Collector — only the three instrumented apps push anything, which is the gap #57 closed); full Grafana LGTM = Loki+Tempo+Mimir (GBs); and the OTel Demo (~6 GB). "Assembled, not a blob" is the honest description: OTel Collector contrib for filelog/kubeletstats/k8s_cluster receivers, three Victoria single-node stores, Grafana wiring them as Prometheus/Loki/Jaeger datasources — every piece readable, and the whole thing an on-demand ~1 GiB.
-->

---

# The rule underneath every pick

<div class="grid grid-cols-2 gap-4 mt-2">
  <div class="practice">
    <strong>Pinned by digest</strong><br>
    Every image is a <code>sha256:</code>, never <code>:latest</code> — a floating tag silently defeats a pre-pulled cache.
    <div class="mod">scripts/images.txt · check-consistency.sh enforces it</div>
  </div>
  <div class="practice">
    <strong>Pre-pulled &amp; offline</strong><br>
    Nothing is fetched at the venue — no CDN, no Grafana plugin download, no Docker Hub live pull.
    <div class="mod">cloudbox-init.sh → local mirror</div>
  </div>
  <div class="practice">
    <strong>Assembled, not a blob</strong><br>
    Hand-written minimal manifests where a Helm chart would drag in StatefulSets, sidecars, PDBs.
    <div class="mod">rustfs · nats · grafana · victoria-*</div>
  </div>
  <div class="practice">
    <strong>Fits a 16 GB laptop</strong><br>
    In-cluster total ≈ 7.5–8 GB; ≥10 GB to Docker. Every pick optimises for this ceiling.
    <div class="mod">the constraint that shaped the whole stack</div>
  </div>
</div>

<div class="mt-6 text-sm opacity-80">
Change the constraints — a real datacenter, a compliance regime, a 10-person platform team — and some of these picks flip. <strong>That</strong> is the transferable skill: not the tools, but reading the tradeoff.
</div>

<!--
The payoff slide: the stack isn't a "best tools" list, it's the answer to one specific constraint set, and naming the constraints is what makes the reasoning portable. This is also the honest bridge to production — say it out loud: "at work you'd swap local-path for a real CSI, RustFS for MinIO-or-S3, in-cluster Gitea for your actual GitHub/GitLab, and add cert-manager and the OTel Operator. The *shape* stays identical; the parts change with the constraints."

The digest-pinning point is not pedantry: a single :latest anywhere means a laptop pulls at the venue and the offline story collapses. The consistency check fails CI if a manifest image and scripts/images.txt drift. Land the sovereignty callback: pinned + offline + Apache-2.0 is also what makes the repo still build this exact platform in a year.
-->
