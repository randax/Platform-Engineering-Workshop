# Vendored: demo (first-party)

| | |
|---|---|
| Source | **This repo.** Nothing is vendored from upstream — every file here is workshop material written for the labs it belongs to (`lab/02-gitops`, `lab/03-data`, `lab/04-self-service`, `lab/06-serverless`, `lab/08-portal`). |
| Images | None of its own. `hello-site.yaml` and `hello-ksvc.yaml` run pre-pulled images already on `scripts/images.txt`; `postgres-cluster.yaml` deliberately leaves `imageName` **unset** so CloudNativePG picks its own pinned default, which is pre-pulled with the operator. |
| Files | `welcome.yaml` · `postgres-cluster.yaml` · `my-database.yaml` · `hello-site.yaml` · `hello-ksvc.yaml` · `portal-access.yaml` · `portal-projects-access.yaml` |

## Re-vendor

Nothing to re-vendor. These are teaching artifacts, not upstream copies — they
change when a lab changes, and the canonical end-state copies live under
`solutions/module-0*/components/demo/`, which `check-consistency.sh` compares
against this directory.

## Knobs

| Knob | What it is for |
|---|---|
| `ghcr.io/knative/helloworld-go` (digest-pinned) | The ksvc's image in `hello-ksvc.yaml`. Upstream publishes only `:latest`, so it is pinned **by digest** here and on `scripts/images.txt` — a floating tag would defeat the pre-pull and break the offline rule. |
| `TARGET` | The one env var `helloworld-go` reads; it prints "Hello ${TARGET}!". Set to *your own cloud*, so the curl in module 06 answers with the day's thesis. |
| `autoscaling.knative.dev/window: "30s"` | Knative's stable-window: how long the autoscaler averages before deciding. The default 60s makes scale-to-zero take longer than an attendee will wait, and watching 1 → 0 happen is the module. |
| node-side image ref `localhost:30500/hello-site:v1` | Module 07's Deployment image, and the one place a node-local port is the correct spelling on both substrates: the build **pushed** to `zot.zot.svc.cluster.local:5000` (cluster DNS, resolvable from pods), but the **kubelet** pulls as the node, where Zot answers on that NodePort — and a tbx VM cannot resolve the ingress hostname. Same image, two names, and the mismatch is the lesson. |
| ports `8080` / `80` | `hello-site`'s container listens on 8080; its Service publishes 80. Two numbers so the Service is visibly a mapping, not a passthrough. |
| `10m` / `16Mi`, `25m` / `32Mi` | Requests for `hello-site` and the ksvc. Deliberately tiny: on a 16 GB laptop every request competes with the platform, and these workloads are proof-of-life, not load. |
| `100m` / `256Mi` / `512Mi` | The CNPG cluster's requests and limits in `postgres-cluster.yaml` — a laptop-sized Postgres. The same numbers appear in `gitops/components/platform-api/`, where the T-shirt `size` patches them. |
| rbac `workshopdatabases` (`create/get/list/patch/delete`) | `portal-access.yaml`: the Console's self-service grant, namespace-scoped. `patch` rather than `update` because the portal only ever changes `spec.size` — there is no full-object update path in the code. |
| rbac `applications`, `services` | `portal-projects-access.yaml`'s `portal-tenant` ClusterRole: the tenant verbs the Console gets *inside a project* — golden-path `applications.platform.cloudbox.io` and Knative `services.serving.knative.dev`. |
| rbac `clusterroles` (verb `bind`, `resourceNames: [portal-tenant]`) | The escalation guard, and the most load-bearing line in this directory. It lets the portal bind exactly one ClusterRole into a namespace it creates and nothing else — without `bind`, an account cannot create a RoleBinding to a role it does not already fully hold. This is why "New project" can stand up a tenant but cannot make the portal cluster-admin. |

## Design decisions recorded here

- **This is the attendee's namespace, not a platform component.** The `demo`
  namespace is where a workshop participant's own resources land. Every file
  here is something the lab asks them to copy into *their* platform repo and
  push; nothing in this directory is enabled from `gitops/catalog/`.
- **`welcome.yaml` is a ConfigMap on purpose.** Module 02's first git-delivered
  resource has to be something that cannot fail for an interesting reason: no
  image to pull, no CRD to wait for, no controller to reconcile. `owner` carries
  the attendee's own name so the ArgoCD diff is visibly *theirs*.
- **`postgres-cluster.yaml` runs `instances: 1` and 1Gi `storage`.** HA needs
  three and a laptop pays for each one; the comment in the file says so, because
  the honest-spec rule applies to lab material too. `bootstrap.initdb` creates
  database `app` owned by `app`, and CNPG generates the `app-db-app` Secret —
  which is what the Console's query terminal reads later.
- **`my-database.yaml` is the developer half of module 04.** Ten lines of
  `WorkshopDatabase` against the XRD in `gitops/components/platform-api/`: the
  point is that the attendee switches hats, from the platform engineer who
  defined the API to the developer who consumes it.
- **`hello-site.yaml` (Deployment + Service) and `hello-ksvc.yaml` (Knative
  Service) are deliberately the same app twice** — module 07 deploys the image
  its own cluster built; module 06 deploys the scale-to-zero shape. Comparing
  the two manifests is the lesson.
- **`portal-access.yaml` and `portal-projects-access.yaml` ship from HERE, not
  from the portal component.** They are the namespace-scoped grants that let the
  Console act in a tenant namespace: `workshopdatabases` self-service, and the
  `namespaces` + `rolebindings` + `bind` on `portal-tenant` that "New project"
  needs. They live beside the `demo` namespace because the portal component
  syncs at wave 3, before this namespace exists — shipping them from there would
  fail the dry-run and block every later wave (see
  `gitops/components/portal/VENDOR.md`). Module 08 teaches pushing the grant as
  a one-file change; until it lands the Databases page shows a friendly
  forbidden error, which is the intended lesson: *grant via git, act via
  console*.
