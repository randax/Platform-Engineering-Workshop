# Module 07 (stretch): CI on your terms, build inside the cluster

## The goal

Your cluster builds its own container images: an Argo Workflow runs BuildKit
(rootless) *inside* the cluster, builds the tiny app in [`app/`](app/) from your
in-cluster Gitea, pushes it to your in-cluster Zot registry, and a Deployment runs it.
Git, build, registry, deploy: all on your laptop's cloud.

## Why this matters

CI is the last thing teams believe they can self-host, but a build is just a pod with
elevated filesystem tricks: BuildKit replaced the archived Kaniko as the 2026
in-cluster answer, and a registry is a single binary (Zot, CNCF). Once
build → push → deploy closes inside your platform, the loop is yours.

## The task

Everything goes through the module-02 write path: your Gitea clone, commit, push.

1. Enable **two** catalog apps: `zot.yaml` (registry, NodePort 30500) and
   `argo-workflows.yaml` (workflow engine + the `build-and-push` WorkflowTemplate in
   ns `builds`, PSA-privileged because rootless BuildKit needs an unconfined seccomp
   profile; find that label).
2. Look at [`app/`](app/): a Dockerfile and one HTML file, already seeded into your
   Gitea repo. The `FROM` line pulls from *your* Zot, not Docker Hub.
3. **Seed the base image**: copy busybox into your registry through Zot's ingress
   hostname. `crane copy` copies registry-to-registry from your own mirror (already
   warm from the pre-pull), so no internet is needed. Which mirror depends on your
   cluster backend (`cat ~/.cloudbox/substrate`):

   ```bash
   MIRROR=localhost:5001                 # docker / kind: the cloudbox-mirror container
   if [ "$(cat ~/.cloudbox/substrate)" = tbx ]; then
     # tbx: talos-box's own docker.io listener on your cluster gateway (172.30.<n>.1)
     MIRROR="$(tbx status cloudbox -o json | jq -r '.[0].subnet | sub("\\.0/24$"; ".1")'):5055"
   fi

   # --platform: ONE architecture, the NODES' (node_arch asks the backend: the
   # host CPU on tbx, the Docker daemon on docker; a Rosetta shell's uname lies).
   # On tbx the warmed store only holds that arch's blobs, so a full-index copy
   # would reach for the internet.
   NODE_ARCH="$(bash -c 'SCRIPT_DIR="$1/scripts"; source "$1/scripts/lib.sh" >/dev/null 2>&1; node_arch' _ "$(git rev-parse --show-toplevel)")"
   mise x crane@0.21.9 -- crane copy --insecure --platform "linux/${NODE_ARCH}" \
     "${MIRROR}/library/busybox:1.37.0" zot.cloudbox.k8s.test/library/busybox:1.37.0
   ```

   The mirror speaks plain HTTP; `crane --insecure` probes HTTPS, gets an immediate
   non-TLS answer, and falls back. (If the mirror is unreachable,
   `docker.io/library/busybox:1.37.0` works as a source, but then you're online.)
   That's the platform-team move: you decide what base images exist in your cloud.

   <details>
   <summary>If the copy hangs: no output, no error, just nothing</summary>

   Don't wait it out. A registry that accepts the connection without answering leaves
   `crane` silently retrying `net/http: TLS handshake timeout`. On tbx that means a
   stalled `tbxd`: check `curl -m5 http://<gateway>:5055/v2/` and `tbx system status`,
   then `tbx system restart` if the daemon is wedged (randax/talos-box#498). Ctrl-C
   and give the copy a deadline so a bad source fails in seconds:

   ```bash
   # same copy, but it gives up instead of hanging (issue #215)
   ( mise x crane@0.21.9 -- crane copy --insecure --platform "linux/${NODE_ARCH}" \
       "${MIRROR}/library/busybox:1.37.0" zot.cloudbox.k8s.test/library/busybox:1.37.0 & \
     pid=$!; ( sleep 45; kill "$pid" 2>/dev/null ) & wait "$pid" ) \
     || echo "the mirror did not answer; use docker.io/library/busybox:1.37.0 as the source instead"
   ```
   </details>
4. Submit a build with [`workflow-run.yaml`](workflow-run.yaml) and follow it to
   `Succeeded`. Then prove the artifact is real: ask Zot's API
   (`http://zot.cloudbox.k8s.test`, standard OCI `/v2/` endpoints) what's in the
   registry.
5. Run the image: deliver [`hello-site.yaml`](hello-site.yaml) via GitOps, then curl
   the page it serves.
6. Run `./verify.sh`.

## Check your work

```bash
./verify.sh
```

## Hints

<details>
<summary>Hint 1: Submitting and following the workflow</summary>

```bash
kubectl create -f workflow-run.yaml     # create, not apply (generateName)
kubectl -n builds get workflows -w      # until Succeeded
# logs of the latest workflow's pods:
kubectl -n builds get pods
kubectl -n builds logs <pod> -f
```

A parameter error on submit means the template's inputs differ; read them:
`kubectl -n builds get workflowtemplate build-and-push -o yaml | head -40`.

If the *build step* fails resolving `zot.zot.svc.cluster.local:5000/library/busybox`,
you skipped seeding (task step 3). Check with
`curl -s http://zot.cloudbox.k8s.test/v2/library/busybox/tags/list`.
</details>

<details>
<summary>Hint 2: Interrogating Zot</summary>

Zot speaks the plain OCI registry API, and has a small web UI at
`http://zot.cloudbox.k8s.test`:

```bash
curl -s http://zot.cloudbox.k8s.test/v2/_catalog | jq .
curl -s http://zot.cloudbox.k8s.test/v2/hello-site/tags/list | jq .
```
</details>

<details>
<summary>Hint 3: The deployment can't pull the image?</summary>

Three views of one registry: the *build* pushed to `zot.zot.svc.cluster.local:5000`
(cluster DNS), the *node* pulls via NodePort 30500 (no cluster DNS there), *you* browse
`http://zot.cloudbox.k8s.test`. If the pull fails: confirm the image exists (hint 2),
then `kubectl -n demo describe pod` and read the exact pull error.
</details>

<details>
<summary>Full solution</summary>

```bash
WORKSHOP="$(git rev-parse --show-toplevel)"
cd ~/cloudbox-platform
cp gitops/catalog/zot.yaml            gitops/apps/
cp gitops/catalog/argo-workflows.yaml gitops/apps/
git add . && git commit -m "module 07: zot + argo-workflows" && git push
# wait for both apps Healthy in ArgoCD

# seed YOUR registry with the pre-pulled base image (host → Zot ingress),
# from your own mirror, same MIRROR selection as step 3, one platform
MIRROR=localhost:5001
[ "$(cat ~/.cloudbox/substrate)" = tbx ] && \
  MIRROR="$(tbx status cloudbox -o json | jq -r '.[0].subnet | sub("\\.0/24$"; ".1")'):5055"
NODE_ARCH="$(bash -c 'SCRIPT_DIR="$1/scripts"; source "$1/scripts/lib.sh" >/dev/null 2>&1; node_arch' _ "$WORKSHOP")"
mise x crane@0.21.9 -- crane copy --insecure --platform "linux/${NODE_ARCH}" \
  "${MIRROR}/library/busybox:1.37.0" zot.cloudbox.k8s.test/library/busybox:1.37.0

kubectl create -f "$WORKSHOP/lab/07-ci/workflow-run.yaml"
kubectl -n builds get workflows -w              # until Succeeded

curl -s http://zot.cloudbox.k8s.test/v2/_catalog | jq .   # hello-site is there

cp "$WORKSHOP/lab/07-ci/hello-site.yaml" gitops/components/demo/
git add . && git commit -m "module 07: run hello-site" && git push
kubectl -n demo rollout status deploy/hello-site

kubectl -n demo port-forward svc/hello-site 8087:80 &
curl -s http://localhost:8087/ | grep hello-site
kill %1
cd "$WORKSHOP/lab/07-ci" && ./verify.sh
```
</details>

## Explain-back

List every network hop in your pipeline (clone from? build where? push to? pull
from?). How many left your laptop? That's the sovereignty argument in one answer.

## Going deeper

- **Rebuild `:v1` and watch nothing happen.** Change `app/index.html`, push to Gitea
  (the build clones from there, not your laptop), submit the same workflow again,
  refresh the page. Nothing changed. Now compare:

  ```bash
  curl -sI http://zot.cloudbox.k8s.test/v2/hello-site/manifests/v1 \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' | grep -i docker-content-digest
  kubectl -n demo get pod -l app=hello-site \
    -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
  ```

  New digest, same tag, old bytes still running: a non-`:latest` tag defaults to
  `IfNotPresent`, so the node never looks again. A tag is a lie you tell yourself; a
  digest is a fact. Module 08's Redeploy mints a fresh tag for this reason, and module
  10 pins digests for it.
- Build `:v2` and roll `hello-site` to it via git: you've reinvented a release
  pipeline. How would you trigger the build on push? (Gitea has webhooks; Argo has
  Events.)
- Inspect the build pod's securityContext mid-build. What does
  `--oci-worker-no-process-sandbox` trade away, and why did `builds` need the PSA
  `privileged` label on Talos?
