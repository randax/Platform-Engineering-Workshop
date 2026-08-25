# Component: gitea (Ingress only — the install itself is not GitOps)

**This directory holds no vendored manifest and no ArgoCD Application.** Gitea
is installed imperatively by `scripts/bootstrap-gitops.sh` from the vendored
chart `scripts/manifests/gitea-12.7.0.tgz` (pin: `scripts/versions.env`
`GITEA_CHART_VERSION`), because the git server has to exist *before* GitOps
does. Re-vendor the chart per `docs/MAINTENANCE.md`, not from here.

The one file here is `ingress.yaml`, and it lives in this directory purely so
every component's ingress reads as one set (`gitops/components/*/ingress.yaml`).
`bootstrap-gitops.sh` applies it directly with `kubectl apply -f` right after
the ArgoCD install, once the `gitea` namespace and Service exist.

## The details a rewrite must reproduce

**`ingress.yaml`** — hand-written; there is no upstream render to diff against.

| | |
|---|---|
| `ingressClassName` | `cilium` — the shared ingress every browser-facing component uses |
| host | `gitea.cloudbox.k8s.test`, literal (YAML is not shell); must equal `scripts/versions.env` `GITEA_HOST_URL` |
| backend | Service `gitea-http`, port **3000**, namespace `gitea` |
| path / pathType | `/` and `Prefix` — Gitea serves its UI, API and the git http protocol all under the root |
| `ingress.cilium.io/request-timeout` | `0s` = **no** timeout. Cilium ingress is an Envoy route, and Envoy's default is 15 s; `seed-gitea.sh` pushes a ~40 MiB pack through here and attendees push through it all day. See `docs/HAZARDS.md`, "NodePorts had no proxy in the path". |

The backend name is not a guess: release `gitea` + chart `gitea` makes
`gitea.fullname` = `gitea` (chart `templates/_helpers.tpl`), and
`gitea.service.http.name` is `<fullname>-http`
(chart `templates/gitea/_services.tpl`) ⇒ `gitea-http`. Port 3000 is the
chart's `service.http.port` default, which `bootstrap-gitops.sh` does not
override. That is the same address as `versions.env` `GITEA_CLUSTER_URL`.

Two things that must NOT change with it:

- **`gitea.config.server.ROOT_URL` stays the in-CLUSTER URL.** It is what
  ArgoCD polls; repointing it at a hostname would make the platform's write
  path depend on host DNS resolving. A `403` or a redirect loop from Gitea
  through this ingress means someone changed it.
- **The NodePort stays.** `service.http.type: NodePort` on `NODEPORT_GITEA`
  (30300) is the docker-substrate fallback for when the `/etc/hosts` block is
  missing; the ingress is an addition, not a replacement.

## Prerequisites

Cilium's ingress controller (installed by `create-cluster.sh`) and, on the
docker substrate, the `/etc/hosts` block
(`./scripts/install.sh --print-hosts`).
