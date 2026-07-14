# Module 03 — Data services: Postgres and S3, on your terms

## The goal

At the end of this module your platform offers two managed data services, both delivered
via git: a PostgreSQL database (CloudNativePG operator) you can `psql` into, and an
S3-compatible object store (RustFS) where you can create a bucket and share a working
presigned URL. `./verify.sh` proves all of it.

## Why this matters

"Managed database" is the single most-bought cloud product, and the thing teams miss most
when leaving a hyperscaler. An operator like CloudNativePG *is* the managed service — the
software that would run behind AWS's console runs in your cluster instead: provisioning,
failover, backups as Kubernetes resources. Same story for object storage. Today you become
the RDS and S3 team — and it's less magic than its price tag suggests.

## The task

Everything goes through the git workflow from module 02 (your Gitea clone).

1. **Enable the two platform components.** The repo has a catalog of ready-made ArgoCD
   Applications in `gitops/catalog/` — enabling one means copying it into `gitops/apps/`
   and pushing. Enable `cnpg-operator.yaml` and `rustfs.yaml`. Watch them come up.

2. **Self-service a database.** This lab dir has a reference manifest,
   [`postgres-cluster.yaml`](postgres-cluster.yaml) — a CNPG `Cluster` named `app-db`.
   Read it (note `storageClass` and `instances`), then deliver it into the `demo`
   namespace *via your repo* (where did module 02 put demo-namespace manifests?).
   Wait for `Cluster in healthy state`, then get a psql prompt in it and run `SELECT 1`.

3. **Claim your object storage.** RustFS speaks S3 on NodePort **30900**
   (access key `cloudbox`, secret `cloudbox123`). Using the `aws` CLI (or `mc`, or a
   3-line script — dealer's choice): create a bucket `app-assets`, upload any file, and
   generate a **presigned URL**. Open it in your browser. That URL is you handing a
   download link to someone with zero AWS involved.

4. Run `./verify.sh`.

## Hints

<details>
<summary>Hint 1: What does "enable from the catalog" concretely look like?</summary>

In your Gitea clone:

```bash
cp gitops/catalog/cnpg-operator.yaml gitops/apps/
cp gitops/catalog/rustfs.yaml       gitops/apps/
git add . && git commit -m "enable cnpg + rustfs" && git push
```

Then watch `kubectl -n argocd get applications -w` (or the UI — Refresh to skip the poll).
The operator lands in ns `cnpg-system`, RustFS in ns `rustfs`.
</details>

<details>
<summary>Hint 2: Delivering the database via git + watching it come up</summary>

Module 02's `demo` Application syncs everything under `gitops/components/demo/` into the
`demo` namespace — so:

```bash
cp <workshop-repo>/lab/03-data/postgres-cluster.yaml gitops/components/demo/
git add . && git commit -m "app-db postgres cluster" && git push
```

Watch it: `kubectl -n demo get cluster app-db -w` (a CNPG cluster does init → one pod →
healthy; first time takes a minute or two). If it sticks, `kubectl -n demo describe
cluster app-db` and `kubectl -n demo get pvc,events`.
</details>

<details>
<summary>Hint 3: Getting a psql prompt (no client install needed)</summary>

Every CNPG pod contains psql, and local socket auth works for the postgres superuser:

```bash
kubectl -n demo exec -it app-db-1 -- psql -U postgres -d app
```

App credentials (for connecting like an application would, via the `app-db-rw` Service)
were generated for you: `kubectl -n demo get secret app-db-app -o yaml`. CNPG made
`app-db-rw` / `app-db-ro` / `app-db-r` Services — rw always points at the primary.
</details>

<details>
<summary>Hint 4: The S3 part with aws CLI</summary>

```bash
export AWS_ACCESS_KEY_ID=cloudbox AWS_SECRET_ACCESS_KEY=cloudbox123 AWS_REGION=us-east-1
aws --endpoint-url http://localhost:30900 s3 mb s3://app-assets
echo "hello from my own cloud" > hello.txt
aws --endpoint-url http://localhost:30900 s3 cp hello.txt s3://app-assets/
aws --endpoint-url http://localhost:30900 s3 presign s3://app-assets/hello.txt --expires-in 3600
```

No `aws` on your machine? Run the whole sequence in the cluster instead (`verify.sh`
wants the uploaded object too, not just the bucket):

```bash
kubectl -n demo run s3 --rm -i --restart=Never \
  --image=public.ecr.aws/aws-cli/aws-cli:2.27.49 \
  --env AWS_ACCESS_KEY_ID=cloudbox --env AWS_SECRET_ACCESS_KEY=cloudbox123 \
  --env AWS_REGION=us-east-1 \
  --command -- /bin/sh -c '
    set -e
    EP=http://rustfs-svc.rustfs.svc.cluster.local:9000
    aws --endpoint-url $EP s3 mb s3://app-assets 2>/dev/null || true
    echo "hello from my own cloud" > /tmp/hello.txt
    aws --endpoint-url $EP s3 cp /tmp/hello.txt s3://app-assets/hello.txt
    aws --endpoint-url $EP s3 presign s3://app-assets/hello.txt --expires-in 3600'
```
</details>

<details>
<summary>Full solution</summary>

```bash
WORKSHOP="$(git rev-parse --show-toplevel)"
cd ~/cloudbox-platform   # your Gitea clone from module 02

cp gitops/catalog/cnpg-operator.yaml gitops/apps/
cp gitops/catalog/rustfs.yaml       gitops/apps/
cp "$WORKSHOP/lab/03-data/postgres-cluster.yaml" gitops/components/demo/
git add . && git commit -m "module 03: cnpg + rustfs + app-db" && git push

kubectl -n demo get cluster app-db -w        # until 'Cluster in healthy state'
kubectl -n demo exec -it app-db-1 -- psql -U postgres -d app -c 'SELECT 1;'

export AWS_ACCESS_KEY_ID=cloudbox AWS_SECRET_ACCESS_KEY=cloudbox123 AWS_REGION=us-east-1
aws --endpoint-url http://localhost:30900 s3 mb s3://app-assets
echo "hello from my own cloud" > /tmp/hello.txt
aws --endpoint-url http://localhost:30900 s3 cp /tmp/hello.txt s3://app-assets/
aws --endpoint-url http://localhost:30900 s3 presign s3://app-assets/hello.txt --expires-in 3600
# open the printed URL in your browser

cd "$WORKSHOP/lab/03-data" && ./verify.sh
```
</details>

## Check your work

```bash
./verify.sh
```

It checks: the cnpg-operator and rustfs ArgoCD apps are Synced/Healthy; the CNPG operator
deployment is up; `app-db` reports healthy with 1/1 ready instances; `SELECT 1` actually
returns 1 from inside the database; RustFS answers S3 on :30900; and bucket `app-assets`
exists with at least one object.

## Explain-back

Tell your neighbor: when you pushed `postgres-cluster.yaml`, list the chain of actors that
turned 30 lines of YAML into a running Postgres (git → ? → ? → pods, PVC, Services,
Secrets). Which of those actors did *you* install, and via what?

## Going deeper

- Kill the database pod (`kubectl -n demo delete pod app-db-1`) and watch the operator
  rebuild it. Where did the data survive?
- Scale to `instances: 3` **via git**, watch replicas join, then check
  `kubectl -n demo get cluster app-db -o yaml` for who's primary. Scale back down (RAM!).
- RustFS is beta software with a rough CVE history — we run it as an ephemeral lab
  sandbox. Discuss: what would *you* need to see before running an S3 clone in prod?
  (This is a real platform-team decision, not a rhetorical one.)

## A note on honesty

MinIO's open-source edition was discontinued in 2025 (not "relicensed"). RustFS is an
independent Apache-2.0 reimplementation of the S3 API — not a MinIO successor. We picked
it to show the *pattern*: S3 is a protocol, and you can self-host a speaker of it.
