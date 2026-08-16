# Vendored: argo-workflows

| | |
|---|---|
| Source | https://github.com/argoproj/argo-workflows |
| Version | **v4.0.8** (latest, 2026-07-22; verified 2026-08-11) |
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
mirrored rules are copied verbatim from namespace-install v4.0.8 and grant, in
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
fetch  https://github.com/argoproj/argo-workflows/releases/download/v4.0.8/namespace-install.yaml

# --- accepted curation: one line per diff hunk (id, then why) ---
allow  namespace-install.yaml  cb5c13bb  sync-wave "-1" on the workflow-controller PriorityClass, so ArgoCD applies it before the Deployment that names it
allow  namespace-install.yaml  fec1f330  argo-server args: --managed-namespace builds and --auth-mode server
allow  namespace-install.yaml  0f18d239  50m/64Mi requests on argo-server (upstream ships none)
allow  namespace-install.yaml  10015baf  workflow-controller arg: --managed-namespace builds
allow  namespace-install.yaml  2b00dc13  50m/64Mi requests on workflow-controller (upstream ships none)
```

Images used:
- `quay.io/argoproj/workflow-controller:v4.0.8`
  (`sha256:7a156419f80285859fc8f859927b6cc249f0d128e161e080dc17fca8fcbbceb6`)
- `quay.io/argoproj/argocli:v4.0.8`
  (`sha256:83e93aa9149a51da998c1df4abea7ae2c504e0b0a5892052dc092740f68323e8`)
- `quay.io/argoproj/argoexec:v4.0.8`
  (`sha256:86a965d7eea176959351156e24f3a2fa8d8e342e477ef425009af95a12e3fe87`) —
  executor, referenced by the controller at runtime, MUST be pre-pulled

The three Argo images above are linux/amd64 + linux/arm64 (digests and
platforms verified with crane 2026-08-11; `argoexec` additionally ships
windows/amd64, unused here).
- `docker.io/moby/buildkit:v0.32.2-rootless` — pinned by tag, not digest: it is
  an OCI image index carrying linux/amd64 + arm64 (+ arm/v7, ppc64le, riscv64,
  s390x), verified with crane 2026-08-11
