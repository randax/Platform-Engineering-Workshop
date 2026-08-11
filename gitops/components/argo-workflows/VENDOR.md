# Vendored: argo-workflows

| | |
|---|---|
| Source | https://github.com/argoproj/argo-workflows |
| Version | **v4.0.8** (latest, 2026-07-22; verified 2026-08-11) |
| Files | `namespace-install.yaml` (patched), `builds.yaml`, `workflowtemplate-build-and-push.yaml` (workshop additions) |

## Re-vendor

```sh
curl -sL -o namespace-install.yaml \
  https://github.com/argoproj/argo-workflows/releases/download/v4.0.8/namespace-install.yaml
```

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
builds get their own `pod-security.kubernetes.io/enforce=privileged`
namespace (`builds.yaml`) while the control plane stays in `argo`.

`builds.yaml` also mirrors `argo-role`/`argo-server-role` into `builds`
(namespace-install RBAC only covers the install namespace) and adds the
executor Role (`workflowtaskresults` create/patch) for the `default` SA.

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
in-cluster and offline-safe.

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
