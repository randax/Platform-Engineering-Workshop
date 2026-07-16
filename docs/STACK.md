# The Stack — Component Choices & Tradeoffs

The reference behind the workshop's ["The stack — and why"](../slides/pages/stack.md)
slides. For each platform component: what we run, what we rejected, and the tradeoff we
took. The authoritative per-component detail lives in each
`gitops/components/*/VENDOR.md`; this is the cross-cutting summary. Versions are the pins
in the manifests and [`scripts/versions.env`](../scripts/versions.env) as of 2026-07-15 —
re-verify before the final `javazone-2026` tag.

Every pick is optimised for the **same three constraints**, not for abstract "best in
class": it must fit a **16 GB laptop**, run **fully offline** at a venue with hostile WiFi,
and be **legible** enough to read in a 4-hour workshop. Change the constraints and some of
these picks flip — reading the tradeoff is the transferable skill, not memorising the tools.

## The table

| Component | Chosen | Rejected alternative | Why |
|---|---|---|---|
| K8s OS | **Talos Linux** v1.13.6 (K8s 1.36.2) | kubeadm · minikube · kind | Immutable, API-only OS — no shell, no SSH, no package manager, no drift. kind stays as the strictly-more-robust fallback. |
| CNI + service proxy | **Cilium** 1.19.5 | flannel + kube-proxy | eBPF datapath, kube-proxy-free — no O(services) iptables, identity-based policy, Hubble. |
| Git server | **Gitea** 1.26.1 (in-cluster) | external GitHub / GitLab | Offline, self-contained write-path; no per-IP NAT rate-limits; attendees can actually push. |
| GitOps engine | **ArgoCD** v3.4.5, app-of-apps | Flux · manual kubectl | Drift detection + self-heal; app-of-apps is the one-cluster shape; plain `install.yaml` teaches better than Helm. |
| Managed Postgres | **CloudNativePG** 1.28.4 (PG 18.4) | bitnami/stock Postgres · cloud RDS | A real control loop (primary+replica, failover, backup) — the operator *is* the "managed" service. |
| Object storage (S3) | **RustFS** 1.0.0-beta.8 | MinIO | Apache-2.0, single ~90 MB Rust binary; MinIO's community edition was discontinued for proprietary AIStor. SeaweedFS is Plan B. |
| OCI registry | **Zot** v2.1.18 | Harbor · Docker registry:2 | One CNCF-native binary with search + UI; Harbor is a Postgres/Redis/Trivy/ChartMuseum fleet. |
| Storage class | **local-path-provisioner** v0.0.36 | Longhorn · Ceph/Rook CSI | Node-local hostPath, one Deployment — no replication/snapshots needed for one node. |
| Self-service API | **Crossplane** v2.3.3 | Helm/operators · Crossplane v1 | Namespaced XRs (no Claims) compose arbitrary K8s resources directly — one YAML → whole stack. |
| Serverless | **Knative** Serving v1.22.1 + Eventing v1.22.2 (Kourier) | plain Deployments · KEDA | Scale-to-zero with request buffering + CloudEvents broker/trigger; it's what Cloud Run is built on. |
| In-cluster CI | **Argo Workflows** v4.0.7 + **BuildKit** v0.31.1 | Tekton · external/cloud CI | Rootless in-cluster image builds → your own Zot, no cloud minutes; Kaniko was archived June 2025. |
| Durable messaging | **NATS** 2.12.12 + JetStream | Kafka · RabbitMQ | The durable streaming primitive in ~15 MB of Go vs. GBs of JVM/Erlang + coordination. |
| Metrics store | **VictoriaMetrics** 1.147.0 | Prometheus | PromQL-compatible, columnar TSDB + `vmrange` histograms — far less RAM for the same series. |
| Log store | **VictoriaLogs** 1.24.0 | Loki | Loki-compatible query API, single node, minimal RAM. |
| Trace store | **VictoriaTraces** 0.9.4 | Grafana Tempo | Jaeger-compatible API; one vendor for metrics/logs/traces (built on VictoriaLogs internally). |
| Telemetry collection | **OTel Collector (contrib)** 0.149.0 | (otel-lgtm had none) | Agent DaemonSet + gateway: filelog/kubeletstats/k8s_cluster/prometheus/OTLP — a real collection layer. |
| Dashboards | **Grafana** 12.4.5 | (part of the LGTM blob) | Built-in Prometheus/Loki/Jaeger datasources, no plugins to fetch → stays offline. |
| Observability (whole) | **Victoria stack + OTel Collector** | kube-prometheus-stack · single-pod otel-lgtm · full LGTM · OTel Demo | Assembled from readable parts, ~1 GiB on-demand where the alternatives want several GB (or ~6 GB). |

## Per-component notes

### Talos Linux — vs. kubeadm / minikube / kind
Talos is an immutable, API-only Linux built solely to run Kubernetes: no shell, no SSH, no
package manager, no `/etc` to hand-edit. The **entire node is one `machineconfig` document**
managed over a gRPC API — the machine is a declarative resource, reconciled like any other.
kubeadm/minikube give you a general-purpose distro you must harden and that can drift; kind
gives you a mutable node you can shell into — which is exactly what Talos refuses to be. The
tradeoff is deliberate: you give up the SSH escape hatch to get zero drift and a tiny attack
surface. Pinned **v1.13.6, never 1.12.x** (`cni: none` docker clusters hung on readiness
until the v1.13.0 fix, talos#12885); default node memory (2048 MB) won't fit the stack, so
the scripts raise it (4096 MB control-plane / 6144 MB worker). **kind + Cilium is the
rehearsed fallback** in-repo — strictly more robust, loses only the Talos content.

### Cilium — vs. flannel + kube-proxy
Cilium does pod networking in eBPF programs in the kernel and **replaces kube-proxy entirely**
(`kubeProxyReplacement`, `k8sServiceHost=localhost`/`:7445` via KubePrism). flannel + kube-proxy
means a set of iptables rules that grows with the number of Services and no L7 awareness.
The tradeoff is a kernel floor (≥5.10 — Docker Desktop macOS 6.10 ✅, WSL2 6.6 ✅, exotic
Linux firewalld/nftables is the risk platform); in return you get identity-based network
policy, Hubble observability, and no kube-proxy pod anywhere in the cluster (a lab
verification step). The fallback keeps kube-proxy on to remove a nested-cgroup variable —
a robustness-vs-wow dial stated honestly.

### Gitea (in-cluster) — vs. external GitHub
The single most important architectural decision for running this at a venue: ArgoCD points
**only at an in-cluster Gitea**, never at GitHub. Attendees can't push to our GitHub (so
they'd get no GitOps experience), and ~50 clusters polling anonymously through one venue NAT
hit GitHub's tightened per-IP limits. Gitea runs single-pod SQLite (`DB_TYPE: sqlite3`,
Postgres/Valkey disabled), `ENABLE_PUSH_CREATE_USER: true`, seeded from the public repo by a
Job. This replicates the CNOE idpbuilder pattern — idpbuilder itself is kind-only
(issue #74), so we copy the pattern and its manifests, not the binary. The cost is one more
pod; the win is a write-path that is entirely offline and entirely yours.

### ArgoCD app-of-apps — vs. Flux / manual kubectl
App-of-apps with sync-wave annotations is the right bootstrap for **one cluster with
disparate components** (ApplicationSets are for stamping *many* clusters). Flux is a heavier
multi-controller surface that's less legible to teach in one sitting; raw `kubectl` has no
drift detection or self-heal. Plain `install.yaml` applied server-side beats Helm for
teaching. The most-missed step: **restore the `Application` health check in `argocd-cm`**
(removed upstream in 1.8) or the waves don't gate. CRD-heavy apps use `ServerSideApply=true`
(Crossplane's CRDs exceed the 262 KB client-side annotation limit); CR-shipping apps use
`SkipDryRunOnMissingResource=true`.

### CloudNativePG — vs. bitnami/stock Postgres or a cloud RDS
CloudNativePG *is* the RDS control loop, running in your cluster: a `Cluster` CR reconciles
into a primary + replica with backups, failover, and rolling upgrades. bitnami's chart is
just a Postgres StatefulSet — a pod, with none of the operational control loop. A cloud
RDS-style service is neither yours nor offline. The tradeoff is an operator plus CRDs (past
the 262 KB annotation limit → `ServerSideApply=true`). Crossplane's compositions compose a
CNPG `Cluster` **directly** — the official Crossplane v2 docs use exactly this example.
Postgres image pinned to the operator's 1.28.4 default (`postgresql:18.4-system-trixie`).

### RustFS — vs. MinIO
An Apache-2.0, S3-compatible object server as a single Rust binary (~90 MB idle, standalone
mode — the chart otherwise defaults to a 4-pod distributed cluster). We reject MinIO because
its open-source community edition was gutted through 2025–26 (console removed May 2025,
binaries stopped Oct 2025, repo archived April 2026) in favour of the proprietary AIStor —
the exact roadmap-capture risk this workshop is about. **State it correctly**: MinIO never
relicensed, and RustFS is an *independent* Apache-2.0 reimplementation, **not** a MinIO
"successor". The tradeoff is maturity: RustFS is at 1.0.0-beta.8, presigned GET/PUT work but
presigned POST doesn't, IAM is console-first, and its security history is rough — acceptable
for an ephemeral lab sandbox and teachable material. **SeaweedFS is the rehearsed Plan B**
(single-pod `allInOne`, stronger IAM) with explicit mid-August switch triggers in
[RESEARCH.md](RESEARCH.md).

### Zot — vs. Harbor / Docker registry:2
Zot is a CNCF, OCI-native registry: one binary, anonymous read/write (workshop-grade),
search + UI extensions on for a visible win at `:30500`. Harbor is the right *enterprise*
pick and the wrong *workshop* pick — it drags in Postgres, Redis, Trivy and ChartMuseum
across many pods. The classic `registry:2` (Docker distribution) has no UI, no search, and
weaker OCI-artifact support. The tradeoff is fewer enterprise features (no built-in
scanning/replication), for a registry an attendee can read top to bottom. BuildKit pushes
with `registry.insecure=true`; Talos machine config mirrors it as insecure so kubelets pull
back.

### local-path-provisioner — vs. a real CSI
The default StorageClass is Rancher's local-path-provisioner: hostPath-backed, one
Deployment, node-local. A real CSI (Longhorn, Ceph/Rook) buys replication and snapshots that
a single-node lab has no use for and can't afford in RAM. Talos-specific curation: the root
FS is immutable, so `nodePathMap` moves to `/var/local-path-provisioner` (bind-mounted into
the kubelet via `machine.kubelet.extraMounts`), and the busybox helper image is pinned.

### Crossplane v2 — vs. Helm/operators for self-service
Crossplane v2 is why self-service is a single YAML. **Claims are gone** — you create a
**namespaced XR directly** — and pipeline-mode compositions (native patch-and-transform
removed) emit **arbitrary K8s resources**, so a composition composes a CNPG `Cluster` +
a bucket Job + a Knative `Service` with no `provider-kubernetes` `Object` wrapping.
Assembling self-service from raw Helm/operators gives you no unified API and nothing
reconciling the composite; Crossplane v1's Claims + Object-wrapping are more concepts to
learn and its old tutorials are now actively misleading. The tradeoff: v2 composes resources
directly, so it needs an **aggregated ClusterRole per composed third-party API group**, and
budgets ~0.7–1 GiB. The Function package is fetched from the registry (not the node image
cache), so enable Crossplane while online or mirror the xpkg into Zot.

### Knative Serving + Eventing — vs. plain Deployments / KEDA
Knative Serving gives request-driven **scale-to-zero** with an activator buffering the first
request (it's the engine under Google Cloud Run); Eventing adds a CloudEvents broker/trigger
data-plane. Plain Deployments are always-on and never scale to zero; KEDA scales on external
metrics but won't buffer a cold request or route by URL. The tradeoff is an activator in the
request path and more control-plane pods — requests are halved (k0s-blog pattern) to ~0.6 GiB.
Kourier is the ingress (Gateway API mode is deliberately avoided — not in Cilium's
conformance matrix). The in-memory channel is **not durable** by design (a 4-hour lab, not
Kafka school).

### Argo Workflows + BuildKit — vs. Tekton / external CI
In-cluster CI as Argo Workflows DAGs, building images with **rootless BuildKit** (`buildctl-
daemonless.sh`) and pushing to the in-cluster Zot — the whole build is in-cluster and
offline. **Kaniko was archived June 2025**, so BuildKit is the 2026 answer. Tekton is a
heavier CRD surface; external/cloud CI needs internet and a cloud account, defeating the
sovereignty premise. The Talos-specific tradeoff: rootless BuildKit needs seccomp/AppArmor
`Unconfined`, which Talos's default PSA `baseline` forbids cluster-wide — so the build
namespace is labelled `pod-security.kubernetes.io/enforce=privileged`. Unrehearsed combo,
spiked early.

### NATS + JetStream — vs. Kafka / RabbitMQ
NATS is a single ~15 MB Go binary; JetStream adds durable streams on a PVC (store caps kept
small — 64 MiB memory / 512 MiB file — a sandbox, not prod). Kafka means a JVM, brokers and
coordination measured in GBs; RabbitMQ means Erlang and more weight. The tradeoff is Kafka's
ecosystem and throughput for a fraction of the RAM — the durable-messaging *primitive*, sized
for a laptop. It's the durable counterpart to the capstone's in-memory broker and the queue
the golden-path `Application` XR requests via `spec.queue`.

### The Victoria stack + OTel Collector — vs. otel-lgtm / kube-prometheus-stack / LGTM
The sharpest tradeoff in the stack, and the one this audience will probe. The **collection
layer** is an OTel Collector (contrib image, for the `filelog`/`kubeletstats`/`k8s_cluster`
receivers the core image lacks): an **agent DaemonSet** (pod logs → VictoriaLogs, kubelet
stats → VictoriaMetrics) and a **gateway Deployment** (`k8s_cluster` + prometheus scrape →
VictoriaMetrics, OTLP receiver on `:4317`/`:4318`). The **stores** are three single-node
Victoria databases — **VictoriaMetrics** (`:8428`, PromQL, replaces Prometheus),
**VictoriaLogs** (`:9428`, Loki API, replaces Loki), **VictoriaTraces** (`:10428`, Jaeger
API, replaces Tempo) — wired into **Grafana** (`:30030`) as **built-in** Prometheus/Loki/
Jaeger datasources, so nothing fetches a plugin at boot (the offline rule).

What we rejected, precisely:

- **single-pod otel-lgtm** — no real Collector, so only the three instrumented apps push
  anything (the gap issue #57 closed by adding the Collector);
- **kube-prometheus-stack** — heavy, and no traces at all;
- **full Grafana LGTM** (Loki + Tempo + Mimir) — GBs of RAM;
- **the OTel Demo** — ~6 GB.

**The RAM win is the point.** VictoriaMetrics' columnar TSDB and `vmrange`-bucketed
histograms hold the same series in far less memory than Prometheus, and VictoriaTraces is
built on VictoriaLogs internally (spans stored as structured logs). The whole observability
layer lands at **~1 GiB, on-demand** (enabled from the catalog as the module-09 capstone, not
wave-0) where the alternatives want several. It is **assembled from readable parts, not one
blob** — every piece a hand-written minimal manifest you can read top to bottom.

## The rule underneath every pick

- **Pinned by digest.** Every image is a `sha256:`, never `:latest` — a floating tag
  silently defeats a pre-pulled cache. `scripts/images.txt` is the manifest;
  `check-consistency.sh` fails CI if a component image and the pre-pull list drift.
- **Pre-pulled & offline.** `cloudbox-init.sh` pulls the pinned list into a local mirror;
  nothing is fetched at the venue — no CDN, no Grafana plugin download, no live Docker Hub
  pull (one anonymous NAT quota for the whole room). Known offline caveats are documented
  (Crossplane Functions, Knative tag-resolving) with mitigations.
- **Assembled, not a blob — hand-written minimal manifests.** Where a Helm chart would drag
  in StatefulSets, config-reloader sidecars and PodDisruptionBudgets a single-node lab
  doesn't need, we hand-write one Deployment + one Service + one ConfigMap so attendees can
  read the whole thing (rustfs, nats, grafana, victoria-metrics/logs/traces). Charts are used
  only where they earn it (crossplane, rustfs, zot rendered via `helm template`, then
  curated).
- **Fits a 16 GB laptop.** In-cluster total ≈ **7.5–8 GB** (Talos 2-node ~1.7, Cilium
  no-Hubble ~0.85, ArgoCD ~0.5, Workflows ~0.2, CNPG+1 PG ~0.3, RustFS ~0.1–0.2, Knative
  ~0.6, Crossplane ~0.7, NATS+JetStream ~0.15, Backstage ~1.5–2, Victoria stack + OTel
  ~1 on-demand) plus Docker VM + OS/browser/IDE ⇒ published spec **16 GB minimum
  (≥10 GB to Docker), 32 GB recommended, 4+ cores, 40 GB free disk**.

Change the constraints — a real datacenter, a compliance regime, a standing platform team —
and some picks flip: local-path → a real CSI, RustFS → MinIO-or-S3, in-cluster Gitea → your
actual GitHub/GitLab, plus cert-manager and the OTel Operator. The **shape** stays identical;
the parts change with the constraints. That is the skill worth taking home.

## See also

- [`docs/RESEARCH.md`](RESEARCH.md) — the grounded research, verdicts, RAM budget and switch triggers.
- [`PLAN.md`](../PLAN.md) — the verdict table and design decisions.
- `gitops/components/*/VENDOR.md` — authoritative per-component detail (why the component, why not the chart).
- [`scripts/versions.env`](../scripts/versions.env) — the single source of truth for version pins.
