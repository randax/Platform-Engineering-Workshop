# Vendored: argo-workflows

| | |
|---|---|
| Source | https://github.com/argoproj/argo-workflows |
| Version | **v4.0.7** (latest, 2026-07-07; verified 2026-07-13) |
| Files | `namespace-install.yaml` (patched), `builds.yaml`, `workflowtemplate-build-and-push.yaml` (workshop additions) |

## Re-vendor

```sh
curl -sL -o namespace-install.yaml \
  https://github.com/argoproj/argo-workflows/releases/download/v4.0.7/namespace-install.yaml
```

## Workshop curation applied (re-apply after re-vendoring)

In `namespace-install.yaml` (both Deployments):

- `workflow-controller` args: added `--managed-namespace builds`
- `argo-server` args: added `--managed-namespace builds` and
  `--auth-mode server` (no SSO/client tokens in a 4-hour lab)

Why managed-namespace: workflow pods run rootless BuildKit, which needs
seccomp/AppArmor `Unconfined`. Talos enforces PSA `baseline` cluster-wide, so
builds get their own `pod-security.kubernetes.io/enforce=privileged`
namespace (`builds.yaml`) while the control plane stays in `argo`.

`builds.yaml` also mirrors `argo-role`/`argo-server-role` into `builds`
(namespace-install RBAC only covers the install namespace) and adds the
executor Role (`workflowtaskresults` create/patch) for the `default` SA.

`workflowtemplate-build-and-push.yaml` modernizes the official
buildkit-template example: git input artifact from the in-cluster Gitea →
`moby/buildkit:v0.31.1-rootless` (tag verified on Docker Hub 2026-07-13,
multi-arch) → anonymous push to Zot with `registry.insecure=true`.

Images used:
- `quay.io/argoproj/workflow-controller:v4.0.7`
- `quay.io/argoproj/argocli:v4.0.7`
- `quay.io/argoproj/argoexec:v4.0.7` (executor — referenced by the controller at runtime, MUST be pre-pulled)
- `docker.io/moby/buildkit:v0.31.1-rootless`
