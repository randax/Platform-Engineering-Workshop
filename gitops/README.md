# gitops/ — the platform tree

This directory **is the platform**. During module 2 the cluster bootstrap
seeds this repo into the in-cluster Gitea
(`http://gitea-http.gitea.svc.cluster.local:3000/cloudbox/platform.git`) and
creates one ArgoCD root Application ("platform", app-of-apps) that watches
`gitops/apps/`. From that point on, **the only way anything reaches the
cluster is a git push** — ArgoCD syncs automatically with prune + selfHeal.

## Layout

```
gitops/
├── apps/          # Application manifests ArgoCD is watching = what is DEPLOYED
│   ├── local-path-provisioner.yaml   (wave 0)
│   └── otel-lgtm.yaml                (wave 0)
├── catalog/       # Application manifests you CAN deploy — the menu
│   ├── cnpg-operator.yaml            (wave 1)
│   ├── rustfs.yaml                   (wave 1)
│   ├── zot.yaml                      (wave 1)
│   ├── crossplane.yaml               (wave 2)
│   ├── knative-serving.yaml          (wave 2)
│   ├── knative-eventing.yaml         (wave 2)
│   ├── argo-workflows.yaml           (wave 2)
│   ├── backstage.yaml                (wave 3)
│   ├── portal.yaml                   (wave 3)
│   └── picture-pipeline.yaml         (wave 3)
└── components/    # the actual Kubernetes manifests, one dir per component
    └── <name>/
        ├── VENDOR.md                 # where it came from + exact re-vendor cmd
        └── *.yaml                    # pinned, vendored, curated manifests
```

## Enabling a capability

Copy the Application from the catalog into `apps/` and push:

```sh
cp gitops/catalog/cnpg-operator.yaml gitops/apps/
git add gitops/apps && git commit -m "enable cnpg-operator" && git push
```

Watch it converge: `kubectl -n argocd get applications -w` (or the ArgoCD UI).
Disabling is the reverse: `git rm` the file from `apps/`, push, and the root
app prunes the child Application (which prunes its resources).

Each catalog entry is designed to work when enabled standalone *in module
order* — the hard dependencies are **backstage → cnpg-operator** (its
database is a CNPG `Cluster`) and **picture-pipeline → knative-serving +
knative-eventing** (module 09: enable serving and eventing before the
pipeline). The **portal** (module 08) is independent, but its gallery page
needs the `images` bucket that picture-pipeline's Job creates, and its
self-service page needs the `demo` namespace from module 04.

## Sync waves

Waves order the children of the root app whenever several sync at once
(bootstrap, catch-up force-pushes). They are annotations on the child
Applications (`argocd.argoproj.io/sync-wave`).

| Wave | Component | Namespace | Why this wave |
|-----:|-----------|-----------|---------------|
| 0 | local-path-provisioner | local-path-storage | everything stateful needs the default StorageClass |
| 0 | otel-lgtm | observability | observability from minute one |
| 1 | cnpg-operator | cnpg-system | CRDs/operator before anything composes databases |
| 1 | rustfs | rustfs | data services |
| 1 | zot | zot | registry before anything builds/pushes |
| 2 | crossplane | crossplane-system | composes CNPG resources (wave 1) |
| 2 | knative-serving | knative-serving (+ kourier-system) | pulls app images from zot |
| 2 | knative-eventing | knative-eventing | broker/trigger mesh for the pipeline |
| 2 | argo-workflows | argo (pods in builds) | pushes to zot |
| 3 | backstage | backstage | heaviest; scaffolds against everything else |
| 3 | portal | portal (+ Role in demo) | Cloudbox Console; reads everything below it |
| 3 | picture-pipeline | pipeline | ksvcs + Broker/Trigger need waves 1–2 (rustfs, serving, eventing) |

Note: wave gating between Applications requires the Application health check
in `argocd-cm` (removed upstream in ArgoCD 1.8, must be restored by the
bootstrap — see docs/RESEARCH.md §3). Without it waves still order the
*apply*, they just don't wait for health.

## How vendoring works (the offline rule)

At the venue **nothing may fetch from the internet**, so no Application
references a remote Helm repo or remote git. Every component is *vendored*:

- upstream release YAML is downloaded, or the upstream Helm chart is rendered
  **once** with `helm template` at a pinned version,
- the output is curated (pins for floating tags, Talos paths, halved
  requests, NodePorts, workshop credentials) and committed under
  `components/<name>/`,
- the Application points at that path *in this same Gitea repo*
  (directory source; `directory.recurse: true` where a component has
  subdirectories).

Every `components/<name>/VENDOR.md` records the source, the exact version,
the exact `helm template`/`curl` command, and every curation applied — so
re-vendoring is mechanical: rerun the command, re-apply the curation list,
diff, commit.

Two things still talk to the network at *enable time* and are pre-pulled /
mirrored by the cluster scripts instead:
- container images (pinned tags/digests — the pre-pull list is derived from
  these manifests),
- the Crossplane Function package (fetched by Crossplane's package manager,
  which bypasses the node image cache — see `components/crossplane/VENDOR.md`
  for the Zot-mirror alternative).

## Conventions

Every Application: `metadata.namespace: argocd`, project `default`,
in-cluster destination, `automated: {prune: true, selfHeal: true}`, retry
(limit 5, exponential backoff), `CreateNamespace=true`, plus per-component
options documented in the header comment of each manifest
(`ServerSideApply` for CRD-heavy apps, `SkipDryRunOnMissingResource` for apps
that ship CRs whose CRDs arrive in the same sync).

Credentials that appear in this tree (`cloudbox`/`cloudbox123`, zot anonymous
read/write, Grafana anonymous admin) are **workshop-grade on purpose**: this
platform is an ephemeral lab sandbox on your own laptop. Every such spot
carries a comment saying so.
