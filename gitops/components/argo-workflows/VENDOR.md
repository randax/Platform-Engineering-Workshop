# Vendored: argo-workflows

| | |
|---|---|
| Source | https://github.com/argoproj/argo-workflows |
| Version | **v4.1.1** (latest; verified 2026-08-17) |
| Files | `namespace-install.yaml` (patched), `builds.yaml`, `workflowtemplate-build-and-push.yaml` (workshop additions) |

## Re-vendor

The recipe lives **once**, in the `curation` block further down this file —
`scripts/check-vendor-drift.sh` runs it, so it cannot rot into a stale copy of
itself. Re-vendoring is: reproduce the file with that recipe, re-apply the
curation below, then `./scripts/check-vendor-drift.sh --only argo-workflows`.

## Workshop curation applied (re-apply after re-vendoring)

In `namespace-install.yaml` (both Deployments):

- `workflow-controller` args: added `--managed-namespace builds`
- `argo-server` args: added `--managed-namespace builds` and
  `--auth-mode server` (no SSO/client tokens in a 4-hour lab)
- added container resource requests **50m/64Mi** to both (upstream ships
  none; small-cluster requests convention, no limits)
- `workflow-controller` **PriorityClass**: annotate
  `argocd.argoproj.io/sync-wave: "-1"` so ArgoCD applies it before the
  Deployment that sets `priorityClassName: workflow-controller`. Without it,
  a fresh ArgoCD sync races (ArgoCD ignores file order) and the controller's
  ReplicaSet hits `FailedCreate: no PriorityClass ... was found`, leaving the
  app Degraded for minutes until the stale `ReplicaFailure` condition clears.

Why managed-namespace: workflow pods run rootless BuildKit, which needs
seccomp/AppArmor `Unconfined`. Talos enforces PSA `baseline` cluster-wide, so
builds get their own privileged namespace (`builds.yaml`) while the control
plane stays in `argo`. All three PSA modes carry it —
`pod-security.kubernetes.io/enforce`, `pod-security.kubernetes.io/audit` and
`pod-security.kubernetes.io/warn` — so the audit log and `kubectl` are not
full of warnings about pods we deliberately allow.

`builds.yaml` also mirrors `argo-role`/`argo-server-role` into `builds`
(namespace-install RBAC only covers the install namespace) and adds the
executor Role (`workflowtaskresults` create/patch) for the `default` SA. The
mirrored rules are copied verbatim from namespace-install v4.1.1 and grant, in
`builds` only: `leases`; `pods`, `pods/exec`, `pods/log`; `configmaps`;
`secrets`; `serviceaccounts`; `events`; `persistentvolumeclaims` and
`persistentvolumeclaims/finalizers`; `poddisruptionbudgets`; and the Argo kinds
`workflows`, `workflows/finalizers`, `workflowtemplates`,
`workflowtemplates/finalizers`, `workflowtasksets`,
`workflowtasksets/finalizers`, `workflowtaskresults`, `workflowartifactgctasks`,
`workfloweventbindings`, `cronworkflows`, `cronworkflows/finalizers`,
`eventsources` and `sensors`. They are listed rather than summarised so a
re-vendor that widens the mirror shows up as a doc change too.

`workflowtemplate-build-and-push.yaml` modernizes the official
buildkit-template example: git input artifact from the in-cluster Gitea →
`moby/buildkit:v0.32.2-rootless` (tag verified on Docker Hub 2026-08-11,
multi-arch) → anonymous push to Zot with `registry.insecure=true`. It also
ships a `buildkitd-config` ConfigMap (`builds` namespace) marking
`zot.zot.svc.cluster.local:5000` as plain-HTTP, mounted at
`/home/user/.config/buildkit/buildkitd.toml` — rootless buildkitd's default
config path (`~/.config/buildkit/buildkitd.toml`, uid 1000, home
`/home/user`; per moby/buildkit docs/buildkitd.toml.md). BuildKit does its
own FROM pulls and pushes inside the pod (the node registry mirror does not
apply), so with Dockerfiles whose FROM points at Zot the whole build is
in-cluster and offline-safe. The build step clones into `/src` (the git input
artifact's path, and the step's `workingDir`), sets
`BUILDKITD_FLAGS=--oci-worker-no-process-sandbox` — rootless buildkitd cannot
create its own process sandbox inside an unprivileged pod — and asks for
250m/512Mi with a 2Gi memory limit, the one step in the workshop that really
does need room.

## What the v4.0.8 → v4.1.1 minor actually changed (2026-08-17)

A minor on a stretch module deserves more than a tag swap, so the release asset
was compared object by object:

- **The non-CRD half of `namespace-install.yaml` differs by exactly two lines**
  — the `argocli` and `workflow-controller` image tags. 19 objects both sides,
  identical inventory. No new or renamed container arg, so `--namespaced`,
  `--managed-namespace` and `--auth-mode server` all still exist and the five
  curations re-applied unchanged (same five hunk ids).
- **`argo-role` and `argo-server-role` are byte-identical to v4.0.8**, so the
  rules `builds.yaml` mirrors into the `builds` namespace are still verbatim
  copies and no verb or resource had to be added.
- **Every CRD change is additive: 1675 added schema paths, ZERO removed**,
  across all eight CRDs. The new fields are `spec.executorPlugins`,
  `podResources`, `resourceClaims` and `pendingTimeout` (on `templates`,
  `templateDefaults`, `tasks` and `workflowSpec`), plus
  `artifacts[].http.saveStreamViaFile` and `artifacts[].s3.addressingStyle`.
  Nothing `workflowtemplate-build-and-push.yaml` uses moved or disappeared: its
  git input artifact, container template, `emptyDir`s, ConfigMap mount and
  resource block validate unchanged.
- **The asset grew 11.1 MB → 12.0 MB**, all of it CRD. That matters because
  `bootstrap-gitops.sh` raises ArgoCD's
  `reposerver.max.combined.directory.manifests.size` to **50M** for exactly this
  file — still ~4x headroom, but this is the pin that eats it, and the comment
  at that call site names the size. `ServerSideApply=true` on the Application
  (`gitops/catalog/argo-workflows.yaml`) is mandatory for the same reason and
  gets more so with every minor.

And from the upstream notes (upgrade guide + CHANGELOG, cross-checked against
the source at both tags):

- **Three breaking changes in 4.1, none of which reach us:** managedFields
  stripped from informer caches (#16563 — about the controller's own cache, not
  cluster objects), `argo archive` now accepts a name *or* a UID (#15198 — UID
  callers unaffected), and `INFORMER_WRITE_BACK` removed (we never set it).
  v4.1.1 on top of 4.1.0 is fixes only.
- **The executor RBAC contract did not move.** `docs/workflow-rbac.md` is
  byte-identical between the tags: still `workflowtaskresults` with
  `create, patch`, same API group. That is what the `workflow-executor` Role in
  `builds.yaml` grants, so it stays as-is.
- **Git input artifacts behave identically** — `git.go` is +3 lines net (a
  `SaveStream` stub and a `switch`→`errors.Is` refactor), go-git bumped to
  v5.19.2. Clone/fetch semantics unchanged.
- **The tested Kubernetes window moved in our favour, and is the best argument
  for taking this minor.** `hack/k8s-versions.sh`: v4.0.8 tests min v1.31.9 /
  max **v1.33.1**, v4.1.1 tests min v1.34.9 / max **v1.36.2**. Our cluster is
  exactly v1.36.2 — so on v4.0.8 we ran three minors *above* upstream's tested
  ceiling, and on v4.1.1 we sit exactly on it. (client-go v0.33.1 → v0.35.4.)
- ⚠️ **Do NOT set `initlessPod.enabled: true`.** v4.1.0 adds an opt-in *beta*
  init-less pod layout (#16161) that replaces the init + wait containers with a
  supervisor container and a Kubernetes image volume. The legacy init+wait
  layout is still the default and is unchanged — which is why rootless BuildKit
  in `builds` is unaffected. `grep -rn initlessPod gitops/` must stay empty
  until someone has rehearsed module 07 on the new layout. The only
  securityContext change in the release is inside `newExecContainer`, gated on
  `TemplateTypeResource`; `build-and-push` is a Container template, so it never
  applies.
- **No image repo or tag scheme changed** (`workflow-controller`, `argocli`,
  `argoexec`; argoexec is still the hard-coded `quay.io/argoproj/argoexec:<tag>`
  default). 4.1 publishes a **new** `argo-workflows-crdinstaller` image —
  `namespace-install.yaml` does not reference it, so it deliberately stays out
  of `scripts/images.txt`.
- `v4.0.9` shipped the same day as a patch-only alternative. It was not taken:
  it keeps the old tested-Kubernetes window, which is the one thing 4.1
  genuinely improves for us.

**Not proven here:** nothing ran. The 2026-08-17 rehearsal's module-07 evidence
(BuildKit 2/2 in 15 s, workflow `Succeeded` in a 91 s solve) is against
**v4.0.8**. Re-run module 07 before believing 4.1.1 on a cluster.

### The same list, machine-readable

`scripts/check-vendor-drift.sh` reproduces the pristine upstream artifact from
the `render` recipe below and diffs it against the vendored file. Every hunk
needs an `allow` line here: an unlisted hunk fails (undocumented curation, or
upstream moved under us) and an `allow` line whose hunk has **disappeared**
fails too — that is a curation lost in a re-vendor, which is exactly how these
docs went wrong before. The prose above is the *why*; these lines are only the
bookkeeping that keeps the prose honest. `--update` rewrites the ids; you still
write the label.

```curation
render namespace-install.yaml
fetch  https://github.com/argoproj/argo-workflows/releases/download/v4.1.1/namespace-install.yaml

# --- accepted curation: one line per diff hunk (id, then why) ---
allow  namespace-install.yaml  cb5c13bb  sync-wave "-1" on the workflow-controller PriorityClass, so ArgoCD applies it before the Deployment that names it
allow  namespace-install.yaml  fec1f330  argo-server args: --managed-namespace builds and --auth-mode server
allow  namespace-install.yaml  0f18d239  50m/64Mi requests on argo-server (upstream ships none)
allow  namespace-install.yaml  10015baf  workflow-controller arg: --managed-namespace builds
allow  namespace-install.yaml  2b00dc13  50m/64Mi requests on workflow-controller (upstream ships none)
```

Images used:
- `quay.io/argoproj/workflow-controller:v4.1.1`
  (`sha256:a322f0ecbfc723315012a4f1d50fcbf9e2ec61c4e903b9e2be0650b4ead8ee7c`)
- `quay.io/argoproj/argocli:v4.1.1`
  (`sha256:bf5faea1eb1b811a4406c3275e270268429d6fca7a1482bd39db4aff998d6f7b`)
- `quay.io/argoproj/argoexec:v4.1.1`
  (`sha256:627fcb70198a9451efd83de9d951e929833e09365ed101bbab1876e310bb610a`) —
  executor, referenced by the controller at runtime, MUST be pre-pulled

The three Argo images above are linux/amd64 + linux/arm64 (digests and
platforms verified with crane 2026-08-17; `argoexec` additionally ships
windows/amd64, unused here).
- `docker.io/moby/buildkit:v0.32.2-rootless` — pinned by tag, not digest: it is
  an OCI image index carrying linux/amd64 + arm64 (+ arm/v7, ppc64le, riscv64,
  s390x), verified with crane 2026-08-11
