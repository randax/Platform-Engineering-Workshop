# Module 04: self-service, your platform gets an API

## The goal

Your platform exposes its own API: a developer writes a `WorkshopDatabase` resource
that asks for little more than a name and a size, and gets a Postgres cluster *and*
an S3 bucket, provisioned, wired, and lifecycle-managed. You prove it by pushing
exactly such a resource and running `./verify.sh`.

## Why this matters

Module 03 made *you* capable of provisioning databases; your developers shouldn't need
to know CNPG, storage classes, or RustFS endpoints. You define an API
(`WorkshopDatabase`) and an implementation (a Crossplane Composition); developers
consume the API. That is what `aws rds create-db-instance` is, except you own both
sides now.

⚠️ **A word about training data (yours and your AI's):** this is Crossplane **v2**.
Claims are gone (you create namespaced XRs directly), and Compositions are
pipeline-mode only, emitting plain Kubernetes resources. Most tutorials and most LLM
answers still describe v1. If you or your assistant produce `kind: Claim`,
`claimNames`, or top-level `resources:` in a Composition, that's the past; paste this
repo's XRD and Composition as context and ask for v2 semantics.

## The task

1. Enable `crossplane.yaml` from the catalog (Crossplane v2, the patch-and-transform
   function, and RBAC to manage CNPG clusters and Jobs).

2. **Ship your platform API.** [`platform/`](platform/) has both halves:
   [`xrd.yaml`](platform/xrd.yaml) is *what* developers may ask for (read the
   schema!), [`composition.yaml`](platform/composition.yaml) is *how*. Deliver them
   as a new component + Application (template:
   [`platform-api-app.yaml`](platform-api-app.yaml)) until the XRD reports
   `ESTABLISHED`.

3. **Be the developer.** Push
   [`examples/my-database.yaml`](examples/my-database.yaml) into your demo component
   and watch the stack unfold: the XR, the composed CNPG cluster `my-db-pg`, its
   pods, the bucket Job.

4. Run `./verify.sh`.

## Check your work

```bash
./verify.sh
```

## Hints

<details>
<summary>Hint 1: The mechanics of shipping the API</summary>

In your Gitea clone:

```bash
cp gitops/catalog/crossplane.yaml gitops/apps/
mkdir -p gitops/components/platform-api
cp <workshop-repo>/lab/04-self-service/platform/*.yaml gitops/components/platform-api/
cp <workshop-repo>/lab/04-self-service/platform-api-app.yaml gitops/apps/platform-api.yaml
git add . && git commit -m "platform API: WorkshopDatabase" && git push
```

Crossplane takes ~1–2 min to install; the platform-api app retries until the CRDs exist.
Check: `kubectl get xrd` → `ESTABLISHED True`, and `kubectl get functions.pkg.crossplane.io`.
</details>

<details>
<summary>Hint 2: Watching the composed stack appear</summary>

After pushing the example XR:

```bash
kubectl -n demo get workshopdatabase my-db          # or: kubectl -n demo get wdb
kubectl -n demo describe workshopdatabase my-db      # events show composed resources
kubectl -n demo get cluster,job,pods                 # the real things it made
crossplane beta trace workshopdatabase my-db -n demo # the whole tree, if crossplane CLI is installed
```

`SYNCED True / READY False` while the database boots is normal: readiness bubbles up
from the CNPG cluster's own Ready condition. Give it 2–3 minutes.
</details>

<details>
<summary>Hint 3: It's stuck. Where do I look?</summary>

In dependency order:

1. `kubectl -n crossplane-system get pods`: is Crossplane itself up?
2. `kubectl get functions.pkg.crossplane.io`: is `function-patch-and-transform` Healthy?
3. `kubectl -n demo describe workshopdatabase my-db`: composition errors land in events.
   "cannot compose resources" usually means the function name in the Composition doesn't
   match the installed Function.
4. RBAC: if events say *forbidden*, Crossplane lacks rights on the composed kind
   (`postgresql.cnpg.io` / `batch`). The crossplane catalog app ships that ClusterRole;
   is it synced?
5. The composed pieces themselves: `kubectl -n demo describe cluster my-db-pg`,
   `kubectl -n demo logs job/my-db-bucket`.
</details>

<details>
<summary>Full solution</summary>

```bash
WORKSHOP="$(git rev-parse --show-toplevel)"
cd ~/cloudbox-platform   # your Gitea clone from module 02 (used the remote-add path instead? cd into your workshop checkout)

cp gitops/catalog/crossplane.yaml gitops/apps/
mkdir -p gitops/components/platform-api
cp "$WORKSHOP/lab/04-self-service/platform/xrd.yaml"         gitops/components/platform-api/
cp "$WORKSHOP/lab/04-self-service/platform/composition.yaml" gitops/components/platform-api/
cp "$WORKSHOP/lab/04-self-service/platform-api-app.yaml"     gitops/apps/platform-api.yaml
cp "$WORKSHOP/lab/04-self-service/examples/my-database.yaml" gitops/components/demo/
git add . && git commit -m "module 04: platform API + first WorkshopDatabase" && git push

kubectl get xrd -w                                   # until ESTABLISHED
kubectl -n demo get workshopdatabase my-db -w        # until SYNCED + READY
kubectl -n demo get cluster,job                      # my-db-pg + my-db-bucket
cd "$WORKSHOP/lab/04-self-service" && ./verify.sh
```
</details>

## Explain-back

A teammate asks: "why not just give developers the CNPG YAML from module 03? It was
only 30 lines." Give your two strongest answers.

## One rule the schema cannot enforce

Module 08's `Application` XR composes a Knative Service whose URL puts name and
namespace in one DNS label (`<name>-<namespace>.kn.cloudbox.k8s.test`): together they
must fit in 63 characters, and a hyphen in the *namespace* makes the split ambiguous.
The XRD caps `metadata.name` at 40, and that is as far as a schema can go: a CEL
validation rule cannot read `metadata.namespace`. The Console enforces the pair in
code; `kubectl apply` of a hand-written XR does not. Keep namespaces short and
hyphen-free.

## Going further: the golden path

One example remains unused: `examples/my-application.yaml`, an `Application` XR that
composes a workload, a database and a bucket from a single manifest. That is the shape
[Nav's nais.yaml](https://nais.io) has at national scale, and adventure door 1
(`adventures/1-app-dev.md`) starts exactly there.

## Going deeper

- **Upgrade Postgres by changing one line** (on a throwaway database, never `my-db`):
  create it at `version: "17"`, change the line to `"18"`, push. CNPG runs an in-place
  major upgrade behind your own API; watch the `<name>-pg-1-major-upgrade` Job, then
  prove it with
  `kubectl -n demo exec <cluster>-1 -c postgres -- psql -U postgres -tAc "select version()"`.
  If the Job fails, the cluster waits until you set the version back or delete the XR.
  Day-2 changes through the API a developer already knows are what people pay for.
  Delete the extra database when done.
- Change `size: medium` via git and watch one knob ripple into replicas and storage.
  Then try `size: xlarge`: where does the rejection come from? The T-shirt enum is your
  policy layer (PRD-0006).
- Delete `my-database.yaml` from the repo and push: the whole composed stack is
  garbage-collected. Re-add it.
