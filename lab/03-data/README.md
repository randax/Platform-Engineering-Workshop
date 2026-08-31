# Module 03: data services, Postgres and S3 on your terms

## The goal

Your platform offers two managed data services, both delivered via git: a PostgreSQL
database (CloudNativePG operator) you can `psql` into, and an S3-compatible object store
(RustFS) where you can create a bucket and share a working presigned URL.

## Why this matters

"Managed database" is the single most-bought cloud product, and the thing teams miss
most when leaving a hyperscaler. An operator like CloudNativePG *is* the managed
service: provisioning, failover, backups as Kubernetes resources, running in your
cluster instead of behind AWS's console. Today you become the RDS and S3 team.

## The task

Everything goes through the module-02 write path: your Gitea clone, commit, push.

1. **Enable `cnpg-operator.yaml` and `rustfs.yaml`** from `gitops/catalog/` (copy into
   `gitops/apps/`, push). Watch them come up.

2. **Self-service a database.** Read [`postgres-cluster.yaml`](postgres-cluster.yaml) in
   this lab dir (note `storageClass` and `instances`), then deliver it into the `demo`
   namespace *via your repo* (where did module 02 put demo-namespace manifests?). Wait
   for `Cluster in healthy state`, then get a psql prompt in it and run `SELECT 1`.

3. **Claim your object storage.** RustFS speaks S3 with access key `cloudbox`, secret
   `cloudbox123`. Using any S3 client: create a bucket `app-assets`, upload a file, and
   generate a **presigned URL**. Open it in your browser. That URL is you handing out a
   download link with zero AWS involved.

4. Run `./verify.sh`.

## Check your work

```bash
./verify.sh
```

## Hints

<details>
<summary>Hint 1: What does "enable from the catalog" concretely look like?</summary>

In your Gitea clone:

```bash
cp gitops/catalog/cnpg-operator.yaml gitops/apps/
cp gitops/catalog/rustfs.yaml       gitops/apps/
git add . && git commit -m "enable cnpg + rustfs" && git push
```

Then watch `kubectl -n argocd get applications -w` (or the UI, Refresh to skip the
poll). The operator lands in ns `cnpg-system`, RustFS in ns `rustfs`.
</details>

<details>
<summary>Hint 2: Delivering the database via git + watching it come up</summary>

Module 02's `demo` Application syncs everything under `gitops/components/demo/` into the
`demo` namespace, so:

```bash
cp <workshop-repo>/lab/03-data/postgres-cluster.yaml gitops/components/demo/
git add . && git commit -m "app-db postgres cluster" && git push
```

Watch: `kubectl -n demo get cluster app-db -w` (init → one pod → healthy; the first
time takes a minute or two). If it sticks, `kubectl -n demo describe cluster app-db`
and `kubectl -n demo get pvc,events`.
</details>

<details>
<summary>Hint 3: Getting a psql prompt (no client install needed)</summary>

Every CNPG pod contains psql, and local socket auth works for the postgres superuser:

```bash
kubectl -n demo exec -it app-db-1 -- psql -U postgres -d app
```

App credentials (for connecting like an application, via the `app-db-rw` Service) were
generated for you: `kubectl -n demo get secret app-db-app -o yaml`. CNPG made
`app-db-rw` / `app-db-ro` / `app-db-r` Services; rw always points at the primary.
</details>

<details>
<summary>Hint 4: The S3 part, with a plain S3 client</summary>

RustFS is not "S3-like": it speaks the S3 API, so any S3 client works. Same
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION`, one `--endpoint-url` to
say "not Amazon". We use [s5cmd](https://github.com/peak/s5cmd), a single Go binary,
to make that point without importing a cloud vendor's CLI.

In-cluster form, nothing installed on your laptop (`verify.sh` wants the uploaded
object too, not just the bucket):

```bash
kubectl -n demo run s3 --rm -i --restart=Never \
  --image=docker.io/peakcom/s5cmd:v2.3.0 \
  --env AWS_ACCESS_KEY_ID=cloudbox --env AWS_SECRET_ACCESS_KEY=cloudbox123 \
  --env AWS_REGION=eu-north-1 \
  --command -- /bin/sh -c '
    set -e
    EP=http://rustfs-svc.rustfs.svc.cluster.local:9000
    /s5cmd --endpoint-url $EP mb s3://app-assets
    echo "hello from my own cloud" > /tmp/hello.txt
    /s5cmd --endpoint-url $EP cp /tmp/hello.txt s3://app-assets/hello.txt
    # mb/cp talk to the cluster; the presign is signed for the address YOUR
    # browser uses. Signing is local maths over the URL and the key; no call
    # is made to it. So the two can differ, and here they must.
    /s5cmd --endpoint-url http://s3.cloudbox.k8s.test presign --expire 1h s3://app-assets/hello.txt'
```

(The image's `ENTRYPOINT` is the binary itself, so `--command -- /bin/sh -c` buys you a
shell; the binary is at `/s5cmd`.)

`s5cmd` is already on your PATH (dev-setup installs it, pinned via mise); the AWS CLI
or `rclone` work the same way. Point any of them at the hostname instead:

```bash
export AWS_ACCESS_KEY_ID=cloudbox AWS_SECRET_ACCESS_KEY=cloudbox123 AWS_REGION=eu-north-1
s5cmd --endpoint-url http://s3.cloudbox.k8s.test mb s3://app-assets
echo "hello from my own cloud" > hello.txt
s5cmd --endpoint-url http://s3.cloudbox.k8s.test cp hello.txt s3://app-assets/
s5cmd --endpoint-url http://s3.cloudbox.k8s.test presign --expire 1h s3://app-assets/hello.txt
# the same four with the AWS CLI: s3 mb / s3 cp / s3 presign --expires-in 3600
```
</details>

<details>
<summary>Full solution</summary>

```bash
WORKSHOP="$(git rev-parse --show-toplevel)"
cd ~/cloudbox-platform   # your Gitea clone from module 02 (used the remote-add path instead? cd into your workshop checkout)

cp gitops/catalog/cnpg-operator.yaml gitops/apps/
cp gitops/catalog/rustfs.yaml       gitops/apps/
cp "$WORKSHOP/lab/03-data/postgres-cluster.yaml" gitops/components/demo/
git add . && git commit -m "module 03: cnpg + rustfs + app-db" && git push

kubectl -n demo get cluster app-db -w        # until 'Cluster in healthy state'
kubectl -n demo exec -it app-db-1 -- psql -U postgres -d app -c 'SELECT 1;'

# any S3 client works; hint 4 has the in-cluster form if you have none installed
export AWS_ACCESS_KEY_ID=cloudbox AWS_SECRET_ACCESS_KEY=cloudbox123 AWS_REGION=eu-north-1
s5cmd --endpoint-url http://s3.cloudbox.k8s.test mb s3://app-assets
echo "hello from my own cloud" > /tmp/hello.txt
s5cmd --endpoint-url http://s3.cloudbox.k8s.test cp /tmp/hello.txt s3://app-assets/
s5cmd --endpoint-url http://s3.cloudbox.k8s.test presign --expire 1h s3://app-assets/hello.txt
# open the printed URL in your browser

cd "$WORKSHOP/lab/03-data" && ./verify.sh
```
</details>

## Explain-back

Tell your neighbor: what chain of actors turned 30 lines of pushed YAML into a running
Postgres (git → ? → ? → pods)? Which of them did *you* install?

## Going deeper

- Kill the database pod (`kubectl -n demo delete pod app-db-1`) and watch the operator
  rebuild it. Where did the data survive?
- Scale to `instances: 3` **via git**, check who's primary in
  `kubectl -n demo get cluster app-db -o yaml`, then scale back down (RAM!).
- RustFS is beta with a rough CVE history; here it's an ephemeral lab sandbox. What
  would *you* need to see before running an S3 clone in prod?

## A note on honesty

MinIO's open-source edition was discontinued in 2025 (not "relicensed"). RustFS is an
independent Apache-2.0 reimplementation of the S3 API, not a MinIO successor. We picked
it to show the pattern: S3 is a protocol, and you can self-host a speaker of it.
