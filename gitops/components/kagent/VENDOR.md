# Vendored: kagent

| | |
|---|---|
| Source charts | `oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds` and `oci://ghcr.io/kagent-dev/kagent/helm/kagent` |
| Version | **0.9.12** (2026-07-20; pin this stable release: kagent does not mark its `v0.10.0-beta*` / `v0.10.0-rc*` GitHub releases as prereleases, so `/releases/latest` resolves to a beta — re-confirmed 2026-08-11, when `/releases/latest` reported `v0.10.0-rc1`) |
| Files | `kagent-crds.yaml` (rendered, 8 CRDs) + `kagent.yaml` (rendered workshop profile); `namespace.yaml`, `networkpolicy.yaml` and `ollama-host-hook.yaml` are hand-written and have no upstream to diff against |

## `ollama-host-hook.yaml` — hand-written

An ArgoCD **PostSync hook** (Job + ServiceAccount + Role/RoleBinding, all named
`kagent-ollama-host`) that points the default `ModelConfig` at *this machine's*
host address. It exists because of an ordering fact: `bootstrap-gitops.sh`
resolves `cloudbox_host_gateway()` while the cluster is being built, but kagent
is a catalog capability the attendee enables in module 10 — there is no
`ModelConfig` to patch at bootstrap time. Bootstrap therefore only records the
answer in configmap `kagent/cloudbox-host`, and this hook applies it right after
ArgoCD creates the object.

| | |
|---|---|
| Images | `registry.k8s.io/kubectl:v1.36.2@sha256:b0d792e0…` — the upstream distroless kubectl, pinned to the SAME 1.36.2 as the kubectl tool (`KUBERNETES_VERSION` in `versions.env`, `mise.toml`), multi-arch, added to `scripts/images.txt`. Plus `docker.io/library/busybox:1.37.0`, already on that list, as the init container. |
| Why two containers | `registry.k8s.io/kubectl` is distroless: `crane export … \| tar -t` shows only `bin/kubectl` and `bin/kube-log-runner` — **no shell** to run a read-compare-patch script in, and **no `cp`** to side-load the binary into a shell image. (The ArgoCD image was tried first and rejected the same way: it ships argocd/helm/kustomize/git-lfs, no kubectl.) So the ConfigMap is mounted instead, busybox renders the merge patch from the mounted file, and kubectl — whose entrypoint *is* kubectl — applies it with `--patch-file`. |
| Volumes | `cloudbox-host` ConfigMap with `optional: true` (its absence must not wedge a pod in ContainerCreating) and an `emptyDir` named `work` carrying the rendered patch between the two containers. |
| RBAC | two verbs on one object: `modelconfigs` `get`+`patch` on `default-model-config`. `get` is required, not habit: `kubectl patch <type> <name>` GETs the object through the resource builder before sending the PATCH, so `patch` alone fails 403 with the PATCH never issued (reproduced against a fake apiserver). The ConfigMap needs no rule at all — a kubelet-mounted volume does not go through the ServiceAccount. |
| Hook policy | `argocd.argoproj.io/hook: PostSync` runs it after ArgoCD has created the ModelConfig; `argocd.argoproj.io/hook-delete-policy: BeforeHookCreation` keeps the last run's pod until the next sync, so `kubectl -n kagent logs job/kagent-ollama-host -c render-patch` still says what it decided (the decision is logged by the INIT container; `-c patch` shows kubectl's own line). |
| Security | `runAsNonRoot` at `runAsUser`/`runAsGroup` `65532` (both images' binaries are world-executable and neither needs a home; `HOME=/work` gives kubectl a writable cache dir), `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, all capabilities dropped. |
| Resources | one patch call and exit: busybox requests `10m` CPU / `16Mi` memory (limit `64Mi`), kubectl `10m` / `32Mi` (limit `128Mi`) — invisible in the workshop RAM budget, generous enough never to be OOM-killed halfway. |
| Idempotent | A merge patch that sets the field to the value it already holds is a server-side no-op; when the ConfigMap is absent (docker/CI, where git's default is already right) the init container renders `{}`, an empty merge patch that changes nothing. |
| Why it is not reverted | The kagent Application `ignoreDifferences` `/spec/ollama/host` with `RespectIgnoreDifferences=true` (`gitops/catalog/kagent.yaml`). |

## Re-vendor

The recipe lives **once**, in the `curation` block further down this file —
`scripts/check-vendor-drift.sh` runs it, so it cannot rot into a stale copy of
itself. It renders the two OCI charts straight (`helm template oci://…`), with
no `helm pull` + `tar` detour. Re-vendoring is: reproduce both files with that
recipe, re-apply the curation below, then
`./scripts/check-vendor-drift.sh --only kagent`.

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
  `ModelConfig` uses `qwen3:1.7b` on the attendee host, at `num_ctx: 16384`
  and `num_predict: 1200` rather than the chart's `num_ctx: 64000`. Small
  local models are not presented as hosted-model equivalents; a hosted
  provider is the upgrade path (see the module 10 PRD, issue #132:
  https://github.com/randax/Platform-Engineering-Workshop/issues/132).
  The host's address is a MACHINE fact, not a git fact: `host.docker.internal`
  (the value carried here) is right only on macOS/WSL2 docker — native Linux
  docker needs `10.5.0.1` (`TALOS_SUBNET_GATEWAY`) and a tbx VM needs its
  cluster gateway `172.30.<n>.1`. Nobody hand-edits it any more:
  `scripts/bootstrap-gitops.sh` resolves `cloudbox_host_gateway()` once and
  records it in configmap `kagent/cloudbox-host`; `ollama-host-hook.yaml`
  (above) patches the `ModelConfig` with it at enable-time, and the kagent
  Application `ignoreDifferences` on `/spec/ollama/host` (plus
  `RespectIgnoreDifferences=true`) keeps selfHeal from reverting that patch.
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

### The same list, machine-readable

`scripts/check-vendor-drift.sh` re-runs both renders — charts, version, flags
and the whole workshop values document — and diffs them against the vendored
files. Almost all of kagent's *workshop* curation is in the
values, so the renders are near-pristine: the `allow` lines are inert helm-4
whitespace (these files were rendered with helm 3, and helm 4 lays out blank
lines differently) plus one post-hoc COMMENT above `spec.ollama.host`, which
changes no manifest field. Any other hunk means the chart moved under a value we set, or
someone hand-edited a rendered file.

```curation
render kagent-crds.yaml
chart     oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds
version   0.9.12
release   kagent-crds
namespace kagent
flags     --no-hooks --set kmcp.enabled=false --set substrate.enabled=false

render kagent.yaml
chart     oci://ghcr.io/kagent-dev/kagent/helm/kagent
version   0.9.12
release   kagent
namespace kagent
flags     --no-hooks
values
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
    # local ≤8B models are unreliable at multi-step tool calling). qwen3:1.7b
    # is what cloudbox-init.sh pre-pulls on the host. It replaced qwen3:4b on
    # 2026-08-18 on measurement, not taste: across ten Console investigations
    # against a live scenario-1 fault, 1.7b emitted a real `function_call`
    # every time (4-26 tool calls per run) and finished in 31-106 s, while 4b
    # answered from the prompt with NO tool call in four of five runs — which
    # renders an empty Case file and costs module 10 its centrepiece.
    default: ollama
    ollama:
      provider: Ollama
      model: "qwen3:1.7b"
      # host.docker.internal:11434 is the chart's own default and matches this
      # repo's existing host-reachability convention for Docker Desktop/OrbStack
      # on macOS + WSL2 (see mirror_host_endpoint() in scripts/lib.sh). It is
      # only the DEFAULT: native Linux docker has no host.docker.internal
      # (10.5.0.1 = TALOS_SUBNET_GATEWAY) and a tbx VM resolves neither (its
      # cluster gateway is 172.30.<n>.1). scripts/bootstrap-gitops.sh decides
      # which of the three applies from cloudbox_host_gateway() and writes it to
      # configmap kagent/cloudbox-host; ollama-host-hook.yaml (PostSync) patches
      # the ModelConfig with it when the attendee enables kagent; the kagent
      # Application ignoreDifferences /spec/ollama/host so selfHeal leaves that
      # patch alone. Nothing hand-edits this line — the rendered file carries a
      # comment saying so (allow hunk 90618629 below).
      config:
        host: host.docker.internal:11434
        # Measured on 2026-08-18 against this cluster's module 10 end state.
        # num_ctx: the chart default 64000 costs 9000 MiB of KV cache on top of
        # the weights — 75% of a 12 GB resident footprint, and the thing that
        # does not fit beside a 16 GiB Colima VM. 16384 costs 1792 MiB and is
        # the FLOOR, not a free choice: one k8s_get_events result on this
        # cluster is ~8.2 k tokens on its own, so 8192 overflows on the second
        # turn. num_predict: small models answer a large tool result by
        # generating until something stops them — three runs were observed
        # past 9,000 tokens in one turn — and kagent-controller 0.9.12 cuts the
        # A2A stream at a hardcoded 180 s, which renders as an error card in
        # the Console. Capping each turn bounds the run instead.
        options:
          num_ctx: "16384"
          num_predict: "1200"

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

# --- accepted curation: one line per diff hunk (id, then why) ---
allow  kagent-crds.yaml  39cdd0de  helm 4 emits a blank line before each `---`; this file was rendered with helm 3. Inert whitespace, no manifest changes — it disappears the next time the file is re-vendored with the pinned helm (4.2.4)
allow  kagent.yaml  39cdd0de  helm 4 emits a blank line before each `---`; this file was rendered with helm 3. Inert whitespace, no manifest changes — it disappears the next time the file is re-vendored with the pinned helm (4.2.4)
allow  kagent.yaml  90618629  a post-render comment above `spec.ollama.host`, saying that ollama-host-hook.yaml patches that field from configmap kagent/cloudbox-host at enable-time and that the kagent Application ignoreDifferences it — the one place a reader meets the hardcoded default is the one place that has to say it is not the whole story. Comment only; no manifest change
allow  kagent.yaml  c0b80476  helm 4 keeps two whitespace-only lines in the config ConfigMap that helm 3 stripped — inert, same fix as above
allow  kagent.yaml  277cc02f  helm 4 keeps a single-space line that helm 3 stripped — inert, same fix as above
allow  kagent.yaml  0972f4d7  helm 4.2.4 (the "vanishing empty lines" fix) keeps TWO blank lines before one `---` — after the `kagent-tools` Service — where 4.2.3 kept one. Same helm-3-era artifact as `39cdd0de`, one hunk with its own content id; inert whitespace, no manifest changes
```

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
  controller ingress from every namespace except `kagent` itself and `portal`,
  and from `portal` only to the controller's A2A/API port `8083` (the Console
  is the sole intended caller — see spec #133). The limitation is
  also taught honestly in the module-10 slides.

Rehearsal owns the live checks: a write attempt through the agent's tools is
actually refused, and the NetworkPolicy doesn't break UI/agent/postgres flows.
