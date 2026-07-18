# Research: Kagent current state — version, images, API, backends, RBAC

Resolves issue #123. Researched **2026-07-18** against primary sources (kagent GitHub
repo at tag `v0.9.11`, the `kagent-dev/tools` repo, kagent.dev docs, the GitHub Releases
API, and live OCI registry manifests). Re-verify version pins in late August before the
final freeze — kagent ships roughly weekly.

> **Bottom line for the workshop:** kagent is viable but heavy and fast-moving. Pin
> **v0.9.11** (the current stable line; v0.10 is still a beta series). Images are standard
> multi-arch OCI already on `ghcr.io/kagent-dev/*` and trivially mirrorable, but the core
> agent runtime (`app`) is ~320 MB and the optional doc-search tool is ~800 MB. The k8s
> troubleshooting agent ships **cluster-admin by default** but can be pinned **read-only**.
> The controller exposes a plain HTTP REST API **and** an A2A endpoint on port 8083 with a
> first-party Go client — ideal for a bespoke portal tie-in. No auth in-cluster by default.

---

## 1. Version to pin

- kagent is a **CNCF Sandbox** project (accepted May 22, 2025; first agentic-AI framework
  at that level). Repo: <https://github.com/kagent-dev/kagent>. Originated at Solo.io.
- **Latest stable: `v0.9.11`** (released 2026-07-01). Verified via the Releases API
  (`/repos/kagent-dev/kagent/releases`). The `v0.9.x` line is the maintained stable track
  (v0.9.11 → v0.9.10 → … → v0.9.4).
- **`v0.10.0` is an active beta series** — `v0.10.0-beta7` was the newest tag overall
  (2026-07-13). ⚠️ Gotcha: kagent does **not** set GitHub's `prerelease` flag on its betas,
  so `/releases/latest` returns `v0.10.0-beta7`. Do **not** treat that as stable. The docs
  site's CLI still defaults to an even older `0.9.9`.
- **Verdict: pin `v0.9.11`.** v0.10 introduces the "Agent Substrate" / `AgentHarness` /
  `SandboxAgent` model (bigger, less settled) and should be avoided for a laptop workshop
  until it GAs. Chart version and image tags track the release number **without** the `v`
  prefix (image tag = `0.9.11`).

Sources: [Releases API](https://github.com/kagent-dev/kagent/releases),
[CNCF project page](https://www.cncf.io/projects/kagent/),
[installation docs](https://kagent.dev/docs/kagent/introduction/installation).

## 2. Charts, CRDs, controller architecture

**Two Helm charts, installed CRDs-first** (both OCI, published to `oci://ghcr.io/kagent-dev/kagent/helm/`):

1. `kagent-crds` — the CustomResourceDefinitions (must be installed first).
2. `kagent` — controller, agent runtime, UI, DB, built-in agents/tools.

The `kagent` chart (`helm/kagent/Chart-template.yaml`) pulls in subchart dependencies:
`kmcp` (MCP-server manager, `oci://ghcr.io/kagent-dev/kmcp/helm`), `kagent-tools`
(`oci://ghcr.io/kagent-dev/tools/helm` **v0.2.1**), `substrate` (disabled by default),
`oauth2-proxy` (`~7.0.0`, disabled), `querydoc` + `grafana-mcp` (MCP tools), and one
subchart per built-in agent (see §5).

**CRDs (API group `kagent.dev`, versions `v1alpha1` and `v1alpha2`):**
`Agent`, `ModelConfig`, `ModelProviderConfig`, `ToolServer`, `RemoteMCPServer`,
`MCPServer`, `Memory`, plus (v0.10) `SandboxAgent`, `AgentHarness`. Agents are authored as
`kagent.dev/v1alpha2 Agent` objects — GitOps-friendly (this is the whole selling point:
agents versioned in Git, reconciled by a controller).

**Components at runtime:**
- **Controller** (Go, `kagent-dev/kagent/controller`) — reconciles the CRDs into
  Deployments/Services and serves the HTTP REST + A2A API. Has `/health`, leader election
  when `controller.replicas > 1`.
- **Agent runtime / engine** (`kagent-dev/kagent/app`) — one Deployment **per Agent** running
  the conversation loop. Two runtimes: **Python ADK** (Google ADK, default) or **Go ADK**
  (faster start, lower memory) selected via `spec.declarative.runtime: python|go`.
- **UI** (`kagent-dev/kagent/ui`) — Next.js dashboard + nginx sidecar (see §7).
- **Database** — v0.9.11 **bundles PostgreSQL 18.3-alpine** (`docker.io/library/postgres`);
  creds hardcoded to `kagent/kagent/kagent` for dev. Swap for external PG in prod via
  `database.postgres.url`. (Note: no longer sqlite; the bundled PG is another pod to fund.)
- **kagent-tools** — the MCP server that actually executes `kubectl`/`helm`/etc. (see §5–6).

Sources: [Helm config reference](https://kagent.dev/docs/kagent/resources/helm),
[Chart-template.yaml](https://github.com/kagent-dev/kagent/blob/v0.9.11/helm/kagent/Chart-template.yaml),
[architecture docs](https://kagent.dev/docs/kagent/concepts/architecture),
[k8s agent template](https://github.com/kagent-dev/kagent/blob/v0.9.11/helm/agents/k8s/templates/agent.yaml).

## 3. Container images — sizes & GHCR mirroring

All images are **standard multi-arch OCI (linux/amd64 + linux/arm64)** — Apple-Silicon safe —
and **already hosted on `ghcr.io/kagent-dev/*`**. The chart's default `registry:
cr.kagent.dev` (v0.9.x) is just a vanity **pull-through proxy in front of ghcr** (its
`WWW-Authenticate` realm is literally `ghcr.io/token`). The v0.10/main chart already flips
the default back to `ghcr.io`. **→ Mirroring to the workshop GHCR org is straightforward**
(`crane/skopeo copy`, or point `registry:` at our mirror). Sizes below are **compressed**,
pulled live from the registry on 2026-07-18 (on-disk ≈ 2–2.5×):

| Image | Tag | arm64 | amd64 | Needed? |
|---|---|---|---|---|
| `kagent-dev/kagent/controller` | `0.9.11` | ~37 MB | ~40 MB | yes |
| `kagent-dev/kagent/ui` | `0.9.11` | ~113 MB | ~115 MB | only if UI shown (§7) |
| `kagent-dev/kagent/app` (agent engine) | `0.9.11` | ~310 MB | ~323 MB | **yes** (one image, shared by all agents) |
| `kagent-dev/kagent/skills-init` | `0.9.11` | ~17 MB | ~17 MB | yes (initContainer) |
| `kagent-dev/kagent/tools` | `0.2.1` | ~200 MB | ~215 MB | yes (k8s tools) |
| `docker.io/library/postgres` | `18.3-alpine` | ~90 MB | ~90 MB | yes (bundled DB) — mirror it too (Docker Hub is rate-limited at venue) |
| `kagent-dev/doc2vec/mcp` (querydoc) | `1.1.14` | ~805 MB | ~806 MB | **optional — disable** (doc-search RAG tool, huge) |
| `kmcp`, `grafana-mcp` (`0.2.1`), `oauth2-proxy` (`~7.0.0`) | — | small/optional | | only if used |

**Core offline footprint** (controller + app + skills-init + tools + postgres, k8s agent
only): **~650–800 MB compressed per arch**. Very fit for pre-pull **as long as `querydoc`
and the nine non-k8s built-in agents are disabled**. The real laptop cost is **runtime RAM**,
not image bytes: the `demo` profile deploys **~10 agent Deployments**; each agent pod
requests 256 Mi / limits 1 Gi, plus controller, UI, bundled PG. **Enable only `k8s-agent`**
to stay inside the 13–17 GB landing zone.

Sources: live OCI manifests on `ghcr.io` / `cr.kagent.dev`;
[values.yaml @v0.9.11](https://github.com/kagent-dev/kagent/blob/v0.9.11/helm/kagent/values.yaml);
[tools values.yaml](https://github.com/kagent-dev/tools/blob/main/helm/kagent-tools/values.yaml).

## 4. LLM providers / backends (Ollama & local OpenAI-compatible)

Configured via the `ModelConfig` CRD; the chart's `providers.*` block seeds a default.
Supported providers (docs + chart): **OpenAI, Anthropic, Azure OpenAI, Gemini, Google
Vertex AI, Amazon Bedrock, xAI (Grok), SAP AI Core, Ollama, and "BYO OpenAI-compatible
model"**. Requirement: the model **must support function/tool calling** — agents are
tool-driven.

**Offline-relevant:**
- **Ollama is first-class.** `ModelConfig` fields: `provider: Ollama`, `ollama.host`
  (e.g. `http://ollama.ollama.svc.cluster.local` in-cluster, or the chart default
  `host.docker.internal:11434`), `model` (e.g. `llama3.2`), plus `options.num_ctx`. So a
  fully local, no-egress setup is supported — either an in-cluster Ollama Deployment or the
  host's Ollama.
- **BYO OpenAI-compatible endpoint** is an explicit provider, so any local
  OpenAI-compatible server (vLLM, llama.cpp server, LiteLLM, LocalAI) works via a custom
  base URL.

**Offline caveat:** models that fit a 13–17 GB laptop *and* do tool-calling reliably are
limited; a small local model may make the agent unreliable. This — plus the cloud-default
provider secrets — is why the module may take the "online exception". Decision still open.

Sources: [Ollama provider docs](https://kagent.dev/docs/kagent/supported-providers/ollama),
[providers block @v0.9.11](https://github.com/kagent-dev/kagent/blob/v0.9.11/helm/kagent/values.yaml).

## 5. Built-in agents & toolsets (day-2 ops)

The chart ships **10 built-in agents**, each its own subchart, each independently toggleable
(`<name>-agent.enabled`): **k8s**, helm, istio, kgateway, argo-rollouts, cilium-policy,
cilium-manager, cilium-debug, promql, observability.

The **`k8s-agent`** is the day-2 troubleshooting fit. It's a declarative `Agent` with a
detailed "KubeAssist" system prompt (systematic, least-privilege, safety-first) whose tools
come from the `kagent-tool-server` (a `RemoteMCPServer`). Its enabled `toolNames` include
both **read** tools (`k8s_get_resources`, `k8s_describe_resource`, `k8s_get_events`,
`k8s_get_pod_logs`, `k8s_get_resource_yaml`, `k8s_get_available_api_resources`,
`k8s_get_cluster_configuration`, `k8s_check_service_connectivity`) **and write/exec** tools
(`k8s_apply_manifest`, `k8s_create_resource`, `k8s_patch_resource`, `k8s_delete_resource`,
`k8s_label/annotate…`, `k8s_execute_command`). It advertises A2A skills
`cluster-diagnostics`, `resource-management`, `security-audit`.

The `kagent-tools` server itself exposes tool providers selectable via
`tools.enabledTools`: `k8s, helm, istio, cilium, argo, prometheus, kubescape, utils`
(empty = all).

Sources: [k8s agent template](https://github.com/kagent-dev/kagent/blob/v0.9.11/helm/agents/k8s/templates/agent.yaml),
[tools values](https://github.com/kagent-dev/tools/blob/main/helm/kagent-tools/values.yaml).

## 6. RBAC model — and read-only scoping ✅

Two distinct RBAC subjects:

**(a) Controller** (`kagent-controller` SA). Bound to a `getter-role` (get/list/watch on
core, apps, batch, rbac, gateway.networking) and a broad **`writer-role`**
(create/update/patch/delete on `""`, `apps`, `batch`, `gateway.networking`, plus kagent CRDs)
— because it must materialize agent Deployments. Cluster-scoped by default; **`rbac.namespaces`
narrows the controller to a Role/RoleBinding per listed namespace** (sets `WATCH_NAMESPACES`).

**(b) Tool executor** (`kagent-tools` SA — the pod that actually runs `kubectl`). **This is
the "what can an agent do to my cluster" answer, and by default it is cluster-admin:**

```yaml
# kagent-tools default: rbac.readOnly=false  →  ClusterRole
- apiGroups: ["*"]; resources: ["*"]; verbs: ["*"]
- nonResourceURLs: ["*"]; verbs: ["*"]
```

**It can be scoped read-only** (`kagent-dev/tools` chart values):
- `rbac.readOnly: true` → swaps to a **read-only ClusterRole** (get/list/watch on pods,
  services, configmaps, deployments, events, logs, ingresses, HPAs, …). "Pairs well with
  the `--read-only` CLI flag which disables write operations at the application layer."
- `rbac.allowSecrets: true` (opt-in secret reads), `rbac.additionalRules` (extra read rules
  for CRDs — Istio/Cilium/Argo), `rbac.namespaces` (namespaced Roles instead of cluster),
  `rbac.create: false` (bring your own role), `useDefaultServiceAccount`,
  `tools.k8s.tokenPassthrough` (use the caller's bearer token instead of the pod SA).

**Workshop recommendation:** set `kagent-tools.rbac.readOnly: true` **and** pass
`--read-only`, and optionally trim the k8s agent's `toolNames` to informational-only. This
gives a genuinely safe, read-only "explain my cluster" agent — a good teaching story
(least-privilege, GitOps-reviewed agent permissions) — and dodges the default cluster-admin
footgun. Note: the default is `readOnly: false` "to avoid breaking changes," so **we must set
it explicitly.**

Sources: [controller writer/getter roles](https://github.com/kagent-dev/kagent/tree/v0.9.11/helm/kagent/templates/rbac),
[tools clusterrole.yaml](https://github.com/kagent-dev/tools/blob/main/helm/kagent-tools/templates/clusterrole.yaml),
[tools values.yaml](https://github.com/kagent-dev/tools/blob/main/helm/kagent-tools/values.yaml).

## 7. Kagent's own web UI — offer & how to hide

The `ui` subchart is a Next.js dashboard (chat with agents, view sessions/traces) fronted by
an nginx sidecar that proxies `/api` → controller. Exposed `ClusterIP` on **:8080** by
default (no ingress unless OpenShift `Route`/gateway added). SSO is via an **optional
oauth2-proxy** (`ui.auth.ssoRedirectPath`).

**Can it be disabled?** There is **no clean `ui.enabled: false` toggle** in v0.9.11 — the
chart always renders the UI Deployment/Service. To hide it for the workshop: leave it
`ClusterIP` with **no route/ingress** (default → not reachable), and/or set `ui.replicas: 0`
to skip the pod entirely (saves ~1 Gi RAM + the 115 MB image). The portal (§8) talks to the
controller API directly and does not need the UI. **Recommendation: `ui.replicas: 0`** unless
we deliberately want to show kagent's own chat UI.

Sources: [ui section, values.yaml @v0.9.11](https://github.com/kagent-dev/kagent/blob/v0.9.11/helm/kagent/values.yaml).

## 8. API surface for a bespoke Go portal (diagnostics tie-in)

The controller serves **two HTTP surfaces on port 8083** (the UI's nginx proxies browser
`/api` to it):

**A. Plain REST API** — this is what the built-in UI uses and what a Go portal should use.
There is a **first-party Go client library**: `github.com/kagent-dev/kagent/go/api/client`
(`client.New(baseURL, opts...)` → a `ClientSet` with sub-clients: `Agent`, `Session`,
`ModelConfig`, `Tool`, `ToolServer`, `Memory`, `Feedback`, `Namespace`, `Model`, `Health`,
`Version`). **We can import it directly** instead of hand-rolling HTTP. Identity is passed as
a `user_id` query param + `X-User-ID` header (`WithUserID(...)`) — **there is no auth on the
API itself**; it assumes a trusted network or an oauth2-proxy in front. For an in-cluster Go
portal (our cloudbox-portal), just call
`http://kagent-controller.kagent.svc:8083` with an `X-User-ID` — clean and offline-friendly.

**B. A2A (Agent-to-Agent) protocol** — per-agent A2A server on the same port. Agent card at
`GET /api/a2a/{namespace}/{agent}/.well-known/agent.json`; invoke over the A2A JSON-RPC
protocol (<https://github.com/a2aproject/A2A>). Example:
`curl :8083/api/a2a/kagent/k8s-agent/.well-known/agent.json`. Also reachable via
`kagent invoke --agent … --task …`. Good for a "diagnose this" button that streams an agent
run into the portal.

**Portal verdict:** best path is the **in-cluster REST API via the Go client** for
list/create/session management, plus **A2A** for streaming an agent invocation. No auth
needed in-cluster; add oauth2-proxy only if exposed. No published OpenAPI spec — the Go
client is the contract of record.

Sources: [go/api/client base.go + clientset.go @v0.9.11](https://github.com/kagent-dev/kagent/tree/v0.9.11/go/api/client),
[A2A example docs](https://kagent.dev/docs/kagent/examples/a2a-agents),
[API reference](https://kagent.dev/docs/kagent/resources/api-ref).

## 9. Fit against workshop constraints — summary

| Constraint | Verdict |
|---|---|
| Pin a version | **v0.9.11** (avoid v0.10 betas) |
| Offline after pre-pull | **Feasible for images** (multi-arch on ghcr, ~700 MB core; disable querydoc + non-k8s agents). **LLM backend is the real offline risk** — needs local Ollama/OpenAI-compatible + a tool-calling-capable small model, or take the online exception. |
| Mirror to GHCR | **Yes** — already on `ghcr.io/kagent-dev/*`; mirror core 5 images + `postgres:18.3-alpine`. |
| Talos-in-Docker + Cilium, 13–17 GB | OK **only if** limited to `k8s-agent` + bundled PG + controller (UI `replicas:0`); the demo profile's ~10 agents will not fit. |
| GitOps via ArgoCD app-of-apps from Gitea | Natural fit — agents are `kagent.dev` CRDs, chart is OCI Helm; wrap as an ArgoCD Application. `ServerSideApply=true` recommended (CRD-heavy). |
| Read-only / safe agent | **Yes** — `kagent-tools.rbac.readOnly: true` + `--read-only`; strong teaching story. |
| Portal tie-in | **Strong** — first-party Go REST client + A2A on :8083, no in-cluster auth needed. |
| Hide kagent UI | `ui.replicas: 0` (no clean enable flag). |

**Open decisions to flag to the module owner:** (1) online exception vs. local model for the
LLM backend; (2) whether to show kagent's UI or drive everything through cloudbox-portal;
(3) accept the bundled-Postgres pod or wire kagent to the existing CNPG.
