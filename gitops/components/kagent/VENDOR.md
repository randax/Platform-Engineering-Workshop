# Vendored: kagent

| | |
|---|---|
| Source charts | `oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds` and `oci://ghcr.io/kagent-dev/kagent/helm/kagent` |
| Version | **0.9.12** (2026-07-20; pin this stable release: kagent does not mark its `v0.10.0-beta*` / `v0.10.0-rc*` GitHub releases as prereleases, so `/releases/latest` resolves to a beta — re-confirmed 2026-08-11, when `/releases/latest` reported `v0.10.0-rc1`) |
| Files | `kagent-crds.yaml` (rendered, 8 CRDs) + `kagent.yaml` (rendered workshop profile) |

## Re-vendor

Run from the repository root:

```sh
helm pull oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds --version 0.9.12
helm pull oci://ghcr.io/kagent-dev/kagent/helm/kagent --version 0.9.12
tar -xzf kagent-crds-0.9.12.tgz
tar -xzf kagent-0.9.12.tgz
cat > /tmp/kagent-values-workshop.yaml <<'VALUES'
# CloudBox workshop values for kagent v0.9.12 — deliberately minimal:
# k8s-agent only, doc-search off, UI scaled to zero, tool server read-only.

# cr.kagent.dev is a vanity pull-through proxy in front of ghcr.io (verified
# in the research resolution, issue #123:
# https://github.com/randax/Platform-Engineering-Workshop/issues/123) —
# point straight at ghcr.io so the pinned image refs in scripts/images.txt
# resolve to the canonical host the pre-pull mirror copies from.
registry: "ghcr.io"

ui:
  # No clean ui.enabled flag in this chart (v0.9.12) — replicas: 0 skips the
  # pod (saves ~1Gi RAM + the image) while still rendering the Service/SA so
  # a future workshop iteration can flip it back on.
  replicas: 0

kmcp:
  # MCP-server manager for dynamically-provisioned MCP servers — the k8s-agent
  # reaches its tools via a static RemoteMCPServer (templates/toolserver-kagent.yaml)
  # wired straight to the kagent-tools Service, not via kmcp. Unused by our
  # k8s-agent-only profile; disabling drops its controller pod + image.
  enabled: false

substrate:
  enabled: false # chart default; Agent Substrate harness, not used here

kagent-tools:
  enabled: true
  rbac:
    # The stock chart flag for a read-only tool server (kagent-dev/tools
    # helm/kagent-tools values.yaml) — left explicit here, not just relied
    # on as a default flip, so it stays visible as a teaching artifact: this
    # is what turns the tool executor from cluster-admin into read-only.
    readOnly: true
  tools:
    # Pairs with rbac.readOnly at the application layer: kagent-tools refuses
    # write/exec calls even if a future RBAC change widened the ClusterRole.
    args:
      - "--read-only"

providers:
  # Default ModelConfig points at host-side Ollama — offline-honest baseline
  # (module 10 PRD, issue #132:
  # https://github.com/randax/Platform-Engineering-Workshop/issues/132 —
  # local ≤8B models are unreliable at multi-step tool calling; qwen3:4b is
  # the smallest verified tool-calling model and is what cloudbox-init.sh
  # pre-pulls on the host).
  default: ollama
  ollama:
    provider: Ollama
    model: "qwen3:4b"
    # host.docker.internal:11434 is the chart's own default and matches this
    # repo's existing host-reachability convention for Docker Desktop/OrbStack
    # on macOS + WSL2 (see mirror_host_endpoint() in scripts/lib.sh). Native
    # Linux Docker has no host.docker.internal — those attendees must edit
    # this ModelConfig after `cp` to point at the Talos bridge gateway
    # (TALOS_SUBNET_GATEWAY in scripts/versions.env), same caveat as
    # CLOUDBOX_MIRROR_HOST.
    config:
      host: host.docker.internal:11434

# k8s-agent is the only built-in agent enabled — everything below is
# disabled to keep the offline image list and runtime RAM footprint minimal
# (research resolution, issue #123:
# https://github.com/randax/Platform-Engineering-Workshop/issues/123 — the
# demo profile's ~10 agent Deployments will not fit the workshop's 13-17GB
# idle budget).
kgateway-agent:
  enabled: false
istio-agent:
  enabled: false
promql-agent:
  enabled: false
observability-agent:
  enabled: false
argo-rollouts-agent:
  enabled: false
helm-agent:
  enabled: false
cilium-policy-agent:
  enabled: false
cilium-manager-agent:
  enabled: false
cilium-debug-agent:
  enabled: false

grafana-mcp:
  # Condition is "grafana-mcp.enabled, observability-agent.enabled" (OR) —
  # must disable both to actually drop it; not used without observability-agent.
  enabled: false

querydoc:
  # Doc-search RAG tool — ~800MB image, explicitly out of scope (brief: "doc
  # search off").
  enabled: false

oauth2-proxy:
  enabled: false # chart default; no in-cluster auth needed (workshop-grade)
VALUES
helm template kagent-crds ./kagent-crds --version 0.9.12 --namespace kagent \
  --no-hooks --set kmcp.enabled=false --set substrate.enabled=false \
  > gitops/components/kagent/kagent-crds.yaml
helm template kagent ./kagent --version 0.9.12 --namespace kagent \
  --no-hooks -f /tmp/kagent-values-workshop.yaml \
  > gitops/components/kagent/kagent.yaml
```

## Workshop curation

- **k8s-agent only** — disables the nine other built-in agents
  (`kgateway-agent`, `istio-agent`, `promql-agent`, `observability-agent`,
  `argo-rollouts-agent`, `helm-agent`, `cilium-policy-agent`,
  `cilium-manager-agent`, `cilium-debug-agent`) to stay inside the workshop
  RAM and offline-image budgets. `kmcp`, the unused Substrate harness,
  `querydoc` document search and `grafana-mcp` are disabled for the same
  reason; the k8s-agent uses the static `RemoteMCPServer` rendered here.
- **UI at `replicas: 0`** — chart 0.9.12 has no clean `ui.enabled: false`.
  Its Deployment remains rendered, but no UI pod or RAM cost is incurred.
- **Read-only tools at both layers** — `kagent-tools.rbac.readOnly: true` is
  the stock chart flag and creates the read-only ClusterRole; upstream keeps
  the default `false` "to avoid breaking changes." The explicit
  `--read-only` argument also rejects write and exec calls in the tool server.
- **Host-side Ollama is the offline-honest baseline** — the default
  `ModelConfig` uses `qwen3:4b` on the attendee host. Small local models are
  not presented as hosted-model equivalents; a hosted provider is the
  upgrade path (see the module 10 PRD, issue #132:
  https://github.com/randax/Platform-Engineering-Workshop/issues/132).
  Native Linux users must replace `host.docker.internal` with the Talos
  bridge gateway.
- **Bundled Postgres stays** — this slice keeps upstream's dev-mode database
  and workshop-grade database/user/password credentials
  `kagent`/`kagent`/`kagent`. It is intentionally not wired to the separately
  enabled `cnpg-operator` capability.
- **Two runtime images are dynamic** — the controller creates the Agent
  Deployment from its image ConfigMap during reconciliation, so
  `app:0.9.12` and the `skills-init:0.9.12` init container never appear as
  literal `image:` fields in this static render — they are read from the
  `kagent-controller` ConfigMap keys `IMAGE_TAG` / `SKILLS_INIT_IMAGE_TAG`
  (both `0.9.12`). Both are still pre-pulled for a real offline run.
- **Stable pin despite GitHub's beta trap** — kagent does not set GitHub's
  prerelease flag on `v0.10.0-beta*` / `v0.10.0-rc*` tags, so GitHub's
  "Latest" badge and `/releases/latest` both point at a beta (2026-08-11:
  `v0.10.0-rc1`). Pin the newest **0.9.x** regardless of what
  `/releases/latest` reports; take a 0.10.x only as a deliberate,
  rehearsed decision.
- **The `kagent-tools` image does NOT track the kagent version** — it comes
  from the `kagent-tools` subchart, whose own version/appVersion is `0.2.1`
  and did not move for 0.9.12 (`Chart.lock`: `kagent-tools 0.2.1`). Read the
  tag out of the render after every bump instead of assuming it follows.

Images used (digests + `linux/amd64` and `linux/arm64` presence verified with
crane 2026-08-11):

- `ghcr.io/kagent-dev/kagent/controller:0.9.12`
  `sha256:d1ea7b70bb8d97de9f0774d44b598971c944b3ab4e88294b0bb78e59d1a63c15`
- `ghcr.io/kagent-dev/kagent/tools:0.2.1`
  `sha256:50b431281d3e32666f27a292962fd486aabaac157083a844d037c12137e353aa`
  (subchart-pinned — see the curation note; does **not** follow the kagent version)
- `ghcr.io/kagent-dev/kagent/ui:0.9.12`
  `sha256:1d5ada8d7f65a6b9ad28232463f9fd670c4c20875baa1c8008aaa1f1f988382e`
- `docker.io/library/postgres:18.3-alpine`
  `sha256:54451ecb8ab38c24c3ec123f2fd501303a3a1856a5c66e98cecf2460d5e1e9d7`
  (chart default, unchanged in 0.9.12)
- `ghcr.io/kagent-dev/kagent/app:0.9.12`
  `sha256:5ee30b4584e8de3266eb3cc11f5c46e8627716339d04d14166c50bda5f0f4182`
  (controller-created Agent Deployment)
- `ghcr.io/kagent-dev/kagent/skills-init:0.9.12`
  `sha256:a1152800fbee8b9143877dcebb981b8a3b450c2c0c3904c8c61e8aa7ce87852a`
  (controller-created Agent init container)

## Security posture (workshop decisions, reviewed on PR #151)

Two upstream defaults in chart 0.9.12 are kept deliberately — forking the
vendored render would break VENDOR.md's byte-reproducibility and the
controller's control-plane duties:

- **Controller RBAC is broad** (`kagent-getter-role` wildcard reads incl.
  Secrets; `kagent-writer-role` writes on core/apps/batch). Both bind ONLY to
  the controller ServiceAccount — the control plane that creates/updates the
  per-Agent Deployments. The *agent's* cluster access (the tool path attendees
  interact with) is read-only at both layers: `--read-only` on the tool server
  and the get/list/watch-only `kagent-tools-read-role`.
- **`AUTH_MODE=unsecure`** (no auth on the controller API; identity is a bare
  `X-User-ID` header). Mitigation shipped here: `networkpolicy.yaml` denies
  controller ingress from every namespace except `kagent` itself and `portal`
  (the Console is the sole intended caller — see spec #133). The limitation is
  also taught honestly in the module-10 slides.

Rehearsal owns the live checks: a write attempt through the agent's tools is
actually refused, and the NetworkPolicy doesn't break UI/agent/postgres flows.
