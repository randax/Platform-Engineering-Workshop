# Vendored: kagent

| | |
|---|---|
| Source charts | `oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds` and `oci://ghcr.io/kagent-dev/kagent/helm/kagent` |
| Version | **0.9.11** (pin this stable release: kagent does not mark `v0.10.0-beta*` GitHub releases as prereleases, so `/releases/latest` resolves to a beta) |
| Files | `kagent-crds.yaml` (rendered, 8 CRDs) + `kagent.yaml` (rendered workshop profile) |

## Re-vendor

Run from the repository root:

```sh
helm pull oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds --version 0.9.11
helm pull oci://ghcr.io/kagent-dev/kagent/helm/kagent --version 0.9.11
tar -xzf kagent-crds-0.9.11.tgz
tar -xzf kagent-0.9.11.tgz
cat > /tmp/kagent-values-workshop.yaml <<'VALUES'
# CloudBox workshop values for kagent v0.9.11 — deliberately minimal:
# k8s-agent only, doc-search off, UI scaled to zero, tool server read-only.

# cr.kagent.dev is a vanity pull-through proxy in front of ghcr.io (verified
# in the research resolution, issue #123:
# https://github.com/randax/Platform-Engineering-Workshop/issues/123) —
# point straight at ghcr.io so the pinned image refs in scripts/images.txt
# resolve to the canonical host the pre-pull mirror copies from.
registry: "ghcr.io"

ui:
  # No clean ui.enabled flag in this chart (v0.9.11) — replicas: 0 skips the
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
helm template kagent-crds ./kagent-crds --version 0.9.11 --namespace kagent \
  --no-hooks --set kmcp.enabled=false --set substrate.enabled=false \
  > gitops/components/kagent/kagent-crds.yaml
helm template kagent ./kagent --version 0.9.11 --namespace kagent \
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
- **UI at `replicas: 0`** — chart 0.9.11 has no clean `ui.enabled: false`.
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
  `app:0.9.11` and the `skills-init:0.9.11` init container never appear as
  literal `image:` fields in this static render. Both are still pre-pulled
  for a real offline run.
- **Stable pin despite GitHub's beta trap** — kagent does not set GitHub's
  prerelease flag on `v0.10.0-beta*` tags. Pin v0.9.11 regardless of what
  `/releases/latest` reports.

Images used:
- `ghcr.io/kagent-dev/kagent/controller:0.9.11`
- `ghcr.io/kagent-dev/kagent/tools:0.2.1`
- `ghcr.io/kagent-dev/kagent/ui:0.9.11`
- `docker.io/library/postgres:18.3-alpine`
- `ghcr.io/kagent-dev/kagent/app:0.9.11` (controller-created Agent Deployment)
- `ghcr.io/kagent-dev/kagent/skills-init:0.9.11` (controller-created Agent init container)
