# Research Grounding — JavaZone 2026 Workshop

Researched 2026-07-13 via parallel web-research agents with adversarial verification of
load-bearing claims against primary sources. Version numbers are as of this date — re-verify
in late August before the final pin.

## 1. Talos-in-Docker + Cilium — **GO**

- **Pin Talos v1.13.6** (talosctl AND `--image ghcr.io/siderolabs/talos:v1.13.6`).
  **Never v1.12.x**: `cni: none` docker clusters hung on readiness checks until the fix in
  v1.13.0 ([talos#12885](https://github.com/siderolabs/talos/issues/12885), PR #12896).
- CLI changed in v1.12: it is now `talosctl cluster create docker` (subcommand), with
  `--cpus-controlplanes`, `--memory-controlplanes`, `--memory-workers`, `--workers`.
- **Default node memory limit is 2048 MB — the stack will not fit.** Raise explicitly
  (e.g. `--memory-controlplanes 4096 --memory-workers 6144`).
- Cilium install: machine-config patch `cluster.network.cni.name: none` (+ optionally
  `cluster.proxy.disabled: true`), then Helm after bootstrap with the values from the
  [official Talos Cilium guide](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium):
  `ipam.mode=kubernetes`, `cgroup.autoMount.enabled=false`, `cgroup.hostRoot=/sys/fs/cgroup`,
  securityContext capability lists; if kube-proxy-free: `kubeProxyReplacement=true`,
  `k8sServiceHost=localhost`, `k8sServicePort=7445` (KubePrism). Keeping kube-proxy enabled
  removes a nested-cgroup variable — robustness vs. wow-factor tradeoff.
- Cilium stable 1.19.5; Talos docs use 1.18.x — either fine. Kernel needs ≥5.10:
  Docker Desktop macOS ships 6.10 ✅, WSL2 ships 6.6 ✅ but **WSL2 is the least-verified
  platform for this combo — must test explicitly**. Linux: warn about firewalld/nftables
  ([talos#13609](https://github.com/siderolabs/talos/issues/13609), Fedora, open).
- Proven on Apple Silicon Docker Desktop ([talos discussion #9849](https://github.com/siderolabs/talos/discussions/9849)).
  **No published large-group workshop has done Talos-in-Docker — we absorb pioneer risk**
  (and get a genuinely novel workshop).
- Fallback: **scripted kind + Cilium** (officially documented Cilium dev env, strictly more
  robust; loses the Talos content). Keep it in the repo.
- Talos v1.13.6 ships Kubernetes 1.36.2 — satisfies Knative's ≥1.34 requirement.

## 2. Object storage: RustFS — **conditional GO**, SeaweedFS is Plan B

- RustFS is at **1.0.0-beta.8** (2026-06-10); no GA yet (roadmap said ~July 2026).
  Apache 2.0. Official Helm chart `rustfs/rustfs` 0.8.0 via https://charts.rustfs.com.
- Config for the workshop: `mode.standalone.enabled=true`, `mode.distributed.enabled=false`
  (distributed 4-pod is the default!), `ingress.enabled=false` (port-forward), creds via
  `RUSTFS_ACCESS_KEY`/`RUSTFS_SECRET_KEY` env. ~90 MB idle, arm64 OK, runs as UID 10001.
- S3 coverage: bucket CRUD, put/get, multipart, **presigned GET/PUT ✅**; presigned POST
  (browser form upload) unsupported; `mc admin` does not work; IAM is console-first.
- Security history is rough and must be handled honestly: CVE-2025-68926 (CVSS 9.8 hardcoded
  gRPC token, fixed alpha.78), 26 advisories Dec 2025–Jun 2026, stored-XSS fix follow-up as
  late as 2026-06-26. Acceptable for an ephemeral lab sandbox; teachable material.
- **Switch triggers → SeaweedFS 4.x** (`allInOne.enabled` single pod, ~500 MB, weekly
  releases, stronger IAM): if by mid-August GA hasn't shipped AND a new critical advisory
  lands, or presigned URLs fail in rehearsal. Garage (~200 MB) is lighter but has no
  IAM/policies/versioning.
- **The abstract's claim is factually wrong** and will be fact-checked by this audience:
  MinIO never relicensed — the AGPL code was *discontinued* (console gutted May 2025,
  binaries stopped Oct 2025, repo archived 2026-04-25) in favor of proprietary AIStor; and
  RustFS is an independent Apache-2.0 reimplementation, **not a "successor"**. Fix the
  README wording and say it correctly in slides.

## 3. GitOps: ArgoCD v3 + in-cluster Gitea — the write-path answer

- **ArgoCD v3.4.5** current; v3.5 GA expected ~August (don't chase it). Pin an exact patch.
  Install with `kubectl apply --server-side --force-conflicts` (ApplicationSet CRD exceeds
  client-side annotation limits since 3.3). Plain install.yaml beats Helm for teaching.
- v3 vs v2 gotchas for demos: logs RBAC enforced by default (read-only demo users need
  `logs, get`); annotation-based tracking default; server-side diff GA but **not** default;
  argocd-autopilot is stale — avoid.
- **App-of-apps is the right bootstrap for one cluster with disparate components**
  (ApplicationSets are for many-cluster stamping). Required recipe:
  sync-wave annotations on child Applications; **restore the Application CRD health check
  in `argocd-cm`** (removed in 1.8; without it waves don't gate — most-missed step);
  `SkipDryRunOnMissingResource=true` on CR-shipping apps; `ServerSideApply=true` on
  CRD-heavy apps (Crossplane blows the 262KB annotation limit); automated sync + retry.
- **Git topology (critical):** point ArgoCD **only at an in-cluster Gitea**, never at GitHub:
  attendees can't push to GitHub (no GitOps experience), and ~50 clusters polling anonymously
  through one venue NAT hits GitHub's tightened per-IP limits. Gitea single-pod SQLite mode
  (`postgresql*`/`valkey*` disabled, `DB_TYPE: sqlite3`), `ENABLE_PUSH_CREATE_USER: true`,
  seeded from the public repo by a Job. This replicates the CNOE idpbuilder pattern —
  **idpbuilder itself cannot target an existing cluster** (kind-only, issue #74), so we copy
  the pattern and its stack manifests, not the binary.
- **Catch-up mechanism:** per-module script force-pushes the canonical module-N state to
  Gitea; ArgoCD converges. (Real workshops use scripted reset, not git merges.) Sync cannot
  fix a broken cluster — also ship a nuke-and-rebuild-to-checkpoint script
  (`talosctl cluster destroy` + rebuild, time-budgeted).

## 4. CI/CD: Argo Workflows + BuildKit + Zot (if kept in scope)

- Argo Workflows **v4.0.7**; `namespace-install.yaml`; server-side apply required; emissary
  executor (unprivileged).
- **Kaniko was archived June 2025.** The 2026 in-cluster build answer is **rootless BuildKit**
  (v0.31.x): `buildctl-daemonless.sh`, `--oci-worker-no-process-sandbox`, seccomp/AppArmor
  Unconfined, runAsUser 1000. Modernize the official
  [buildkit-template example](https://github.com/argoproj/argo-workflows/blob/main/examples/buildkit-template.yaml).
- **Talos gotcha:** PSA `baseline` is enforced cluster-wide by default and forbids Unconfined —
  label the build namespace `pod-security.kubernetes.io/enforce=privileged`.
  **No published BuildKit-on-Talos report exists — rehearse early.**
- Registry: **Zot v2.1.18** (CNCF, single binary, Helm chart). BuildKit pushes with
  `registry.insecure=true` to the in-cluster service; add `machine.registries` mirror /
  insecureSkipVerify in Talos machine config so nodes can pull back.

## 5. Platform components

- **Crossplane v2.3.3** (v2 GA Aug 2025; CNCF **graduated** Nov 2025). Teaching deltas:
  Claims are gone (namespaced XRs created directly); pipeline-mode compositions only
  (native P&T removed); **compositions emit arbitrary k8s resources directly — official docs
  compose a CloudNativePG `Cluster` as their example**. No provider-kubernetes wrapping.
  Needs an aggregated ClusterRole per composed third-party API group. Budget ~0.7–1 GiB.
  Old v1 tutorials (Claims, Object-wrapping) are actively misleading now — one slide on this.
- **Backstage v1.52.1**: from-scratch is not lab material (Node build, 6 GB). **CNOE prebuilt
  image (`ghcr.io/cnoe-io/backstage-app`)** ships working software templates wired to
  Gitea + ArgoCD — exactly our loop. 1.5–2 GiB (+ its Postgres); `NODE_ENV=production`.
  Run as the **last** module so low-RAM attendees lose nothing; presenter instance as fallback.
- **Knative Serving v1.22.1** (v1.23 lands ~2026-07-28; pin one). Kourier ingress, halve the
  default requests (official k0s blog pattern) → ~0.6 GiB. Set
  `registries-skipping-tag-resolving` for the local registry. Avoid Gateway API mode with
  Cilium (not in conformance matrix). No published Talos+Knative report — smoke-test.
- **Observability: the Victoria stack + OTel Collector**, enabled on-demand from the catalog
  (not wave-0). Stores: **VictoriaMetrics** (:8428, Prometheus query API — replaces Prometheus),
  **VictoriaLogs** (:9428, Loki-compatible API — replaces Loki), **VictoriaTraces** (:10428,
  **Jaeger**-compatible API — replaces Tempo). **Grafana** (:30030 NodePort) wires all three as
  built-in datasources (Prometheus/Loki/Jaeger types, no plugins — offline rule). The collection
  layer otel-lgtm never had: an **OTel Collector** agent DaemonSet (filelog → VictoriaLogs,
  kubeletstats → VictoriaMetrics) plus a gateway Deployment (k8s_cluster + prometheus scrape →
  VictoriaMetrics; OTLP receiver on :4317/:4318). Skip kube-prometheus-stack (heavy, no traces),
  the single-pod otel-lgtm (no real Collector), and the OTel Demo (~6 GB).

## 6. RAM budget and published spec

In-cluster total ≈ **7.5–8 GB** (Talos 2-node ~1.7, Cilium no-Hubble ~0.85, ArgoCD core ~0.5,
Workflows ~0.2, CNPG+1 PG ~0.3, RustFS ~0.1–0.2, Knative ~0.6, Crossplane ~0.7,
NATS+JetStream ~0.15 (stretch), Backstage ~1.5–2, Victoria stack + OTel Collector ~1
(on-demand, not part of the always-on baseline)) + Docker VM overhead
+ OS/browser/IDE ⇒ landing zone
**13–17 GB**. Publish: **16 GB RAM absolute minimum (≥10 GB allocatable to Docker;
OrbStack or tuned WSL2 strongly advised), 32 GB recommended, 4+ cores, 40 GB free disk.**
Hubble UI: presenter demo only (+0.3 GB per attendee otherwise).
Measure the real assembled stack once in the spike — several figures are estimates.

## 7. Conference logistics (evidence-based)

- **Directly comparable precedent:** JavaZone 2022 hands-on k8s workshop — *"Half of the
  students couldn't get the environment working."* Experienced runners (container.training)
  take laptops off the critical path; their current model is a devcontainer that runs in
  Codespaces (prebuilds) or locally — same content both ways.
- **Never pull from Docker Hub live**: the room shares one NAT IP = one anonymous quota
  (100 pulls/6h — the stricter 2025 limits were announced but never enforced). Host every
  image on **GHCR with pinned tags** (`:latest` silently defeats pre-loaded images).
  Consider a mini-PC pull-through registry in the room (docker-oxford/registry-pi pattern).
- **Pacing reality:** plan ~5 exercises, expect to finish 3. 45–60-min modules: short intro →
  demo → 10–15-min lab → walk the solution to re-sync. Hands on keyboards within the first
  10 minutes. ≥50% hands-on. Bonus challenges for the fast 20%.
- **Staffing:** 1 helper per 8–10 attendees on top of 2 instructors (Carpentries) — recruit
  4–8 helpers (CNCF/GDG networks; workshop helpers get conference access). Two-color sticky
  notes for silent help requests.
- **Checkpoints:** git tag/branch per module + `solutions/` directory + everything public.
- **JavaZone 2026:** Sept 2–3, NOVA Spektrum, Lillestrøm; workshop day historically the
  Tuesday before (likely Sept 1) at Rebel Oslo, 240-min morning slot; sign-up first-come
  ~2 weeks ahead. **Unconfirmed — email organizers:** exact day/venue, seat cap, tables,
  power, wired network, whether outbound SSH is blocked.

## 8. Workshops in the AI-assistant era (2024–2026 evidence)

- Classroom evidence is strong: step-by-step labs no longer measure learning (CHI 2026
  instructor study; 1/3 of a 450-person class scored zero on proctored basics despite fine
  AI-assisted assignment grades). Conference-workshop retrospectives show a **null result** —
  nobody complains yet — but the mechanism transfers; SIGCSE 2025 finding: starter code and
  step lists make tasks *easier* for LLMs, while context-specific/visual/stateful tasks resist.
- Proven patterns (all with verified exemplars):
  - **Broken-on-purpose labs**: SadServers, Klustered, vellankikoti's 35 k8s failure
    scenarios (`issue.yaml`/`fix.yaml`/`description.md` triples), AWS's 5-injected-faults
    workshop.
  - **Goal-oriented labs with automated checkers**: iximiuz/Killercoda model — outcome +
    `verify.sh` (exit-0 contract), many small checks, `FAIL:`-prefixed actionable messages;
    Instruqt's check↔solve CI loop regression-tests the checks themselves.
  - **Layered free hints**: eficode kubernetes-katas template — overview bullets, steps
    collapsed in `<details>`, escalating hint levels; hint *penalties* backfire.
  - **Explain-back checkpoints**: 2-min "tell your neighbor why the fix worked" at module
    boundaries — AI-generated fixes are fine, un-understood fixes aren't done.
  - **AI-embracing segment**: point an agent (Claude Code, kubectl-ai, k8sgpt/HolmesGPT,
    kagent) at the attendee's own cluster to diagnose an injected fault, then verify/falsify
    its answer against live state. Microsoft's AKS agentic workshop and AWS's DevOps-Agent
    EKS workshop prove the format; at KubeCon it's still speaker-demo-only — **attendee
    hands-on agent-vs-cluster is an open lane**.
  - **One "AI got it wrong" exercise**: seed a fault where the obvious LLM diagnosis is
    plausible but incorrect; the 2026 learning objective is *verification* of agent output.
