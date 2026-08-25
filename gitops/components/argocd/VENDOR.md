# Component: argocd (Ingress only — ArgoCD cannot deliver its own front door)

**This directory holds no vendored manifest and no ArgoCD Application.** ArgoCD
is installed imperatively by `scripts/bootstrap-gitops.sh` from the vendored
manifest `scripts/manifests/argocd-install-v3.5.1.yaml` (pin:
`scripts/versions.env` `ARGOCD_VERSION`) — it is the thing that makes GitOps
possible, so it cannot arrive through GitOps. Re-vendor per
`docs/MAINTENANCE.md`, not from here.

The one file here is `ingress.yaml`, and it lives in this directory purely so
every component's ingress reads as one set (`gitops/components/*/ingress.yaml`).
`bootstrap-gitops.sh` applies it directly with `kubectl apply -f`, after the
`server.insecure` patch and the `argocd-server` Service patch.

## The details a rewrite must reproduce

**`ingress.yaml`** — hand-written; there is no upstream render to diff against.

| | |
|---|---|
| `ingressClassName` | `cilium` — the shared ingress every browser-facing component uses |
| host | `argocd.cloudbox.k8s.test`, literal (YAML is not shell); must equal `scripts/versions.env` `ARGOCD_HOST_URL` |
| backend | Service `argocd-server`, port **80** (name `http`, targetPort 8080), namespace `argocd` |
| path / pathType | `/` and `Prefix` — the UI, the API and the gRPC-web endpoint all live under the root |
| `ingress.cilium.io/request-timeout` | `0s` = **no** timeout. The UI holds gRPC-web watch streams open for as long as the tab is, and Envoy — which every hostname now goes through — defaults to 15 s. See `docs/HAZARDS.md`, "NodePorts had no proxy in the path". |

The Service is the one the vendored install ships (`argocd-server`, ports
`http` 80→8080 and `https` 443→8080). The `https` port is deliberately **not**
used: `bootstrap-gitops.sh` patches `argocd-cmd-params-cm` with
`server.insecure: "true"`, so `argocd-server` speaks plain HTTP on 8080.
Pointing the ingress at 443 would only invite a TLS assumption that
`server.insecure` has already removed; and without `server.insecure` the
ingress would be speaking http at a TLS listener and every request would fail.
If that patch is ever dropped, this file needs a backend-protocol annotation.

**The NodePort stays.** `bootstrap-gitops.sh` patches the Service to NodePort
`NODEPORT_ARGOCD` (30080) as the docker-substrate fallback for when the
`/etc/hosts` block is missing; the ingress is an addition, not a replacement.

## Prerequisites

Cilium's ingress controller (installed by `create-cluster.sh`) and, on the
docker substrate, the `/etc/hosts` block
(`./scripts/install.sh --print-hosts`).
