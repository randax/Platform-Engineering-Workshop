# Devcontainer and Codespaces: the lifeboat

If `mise run preflight` won't go green on your machine, don't burn workshop time on it. This
repo ships a [devcontainer](devcontainer.json) with Docker-in-Docker and all
tools preinstalled, the exact same workshop content:

- **GitHub Codespaces**: Code → Create codespace on this repo. Pick a machine with
  **4 cores / 16 GB RAM** or larger, then run the same three prework steps inside it.
- **Locally**: any editor that speaks the [Dev Containers spec](https://containers.dev)
  (VS Code, JetBrains, `devcontainer` CLI), though if Docker works locally you likely don't
  need the lifeboat.

**One thing differs in Codespaces: how you open a service.** Everywhere else the workshop's
URLs are hostnames (`http://gitea.cloudbox.k8s.test`). A codespace's browser is not on the
machine the cluster runs on; it reaches the container through
`https://<codespace>-<port>.app.github.dev`, which sends whatever `Host` header GitHub
chooses, and the platform's ingress routes **by hostname**, so the forwarded port-80 URL
404s on a healthy cluster. Use the **Ports tab** instead: the devcontainer forwards a
NodePort per service, each row opening the right one directly, no `Host` header involved.

| Ports tab entry | Service |
|---|---|
| NodePort 30300 | Gitea (in-cluster git) |
| NodePort 30080 | ArgoCD |
| NodePort 30600 | Cloudbox Console |
| NodePort 30030 | Grafana |
| NodePort 30900 | RustFS S3 |
| NodePort 30500 | Zot registry |
| NodePort 31080 | your apps (Kourier); needs a `Host` header, so `curl` it from the terminal |

Inside the codespace's own terminal the hostnames work normally (`curl` and the labs'
`verify.sh` scripts resolve them from the container's `/etc/hosts`); only the browser needs
the Ports tab.

Codespaces runs in Microsoft's cloud. A pragmatic irony for a sovereignty workshop, and
exactly why it's the lifeboat and not the boat.

