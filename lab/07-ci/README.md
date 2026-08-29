# Module 07 (stretch) — CI on your terms: build inside the cluster

## The goal

At the end of this module your cluster builds its own container images: an Argo Workflow
runs BuildKit (rootless) *inside* the cluster, builds the tiny app in [`app/`](app/) from
your in-cluster Gitea, pushes it to your in-cluster Zot registry, and a Deployment runs
it. Zero external services touched — git, build, registry, deploy all happen on your
laptop's cloud.

> **Honesty note:** this is the least-rehearsed path in the workshop (rootless BuildKit
> on Talos is pioneer territory — nobody has published this combo). It's a presenter demo
> first, self-paced lab second. If it fights you, watch the demo, file the scars, move on.

## Why this matters

CI is the last thing teams believe they can self-host ("we need GitHub Actions!").
But a build is just a pod with elevated filesystem tricks: BuildKit replaced the archived
Kaniko as the 2026 in-cluster answer, and a registry is a single binary (Zot, CNCF).
Once *build → push → deploy* closes inside your platform, the loop is fully yours.

## The task

1. Enable **two** catalog apps: `zot.yaml` (registry, NodePort 30500) and
   `argo-workflows.yaml` (workflow engine + the `build-and-push` WorkflowTemplate in
   ns `builds` — a namespace labeled PSA-privileged because rootless BuildKit needs an
   unconfined seccomp profile; find that label and understand why it's there).
2. Look at [`app/`](app/) — a Dockerfile and one HTML file. Your Gitea repo already
   contains it (it was seeded with the whole workshop repo). Notice the `FROM` line:
   it pulls the base image from *your* Zot, not from Docker Hub — your platform builds
   FROM your own registry, fully offline.
3. **Seed the base image**: copy busybox into YOUR registry (host-side, through Zot's
   ingress hostname). `crane copy` doesn't read your local docker — it's a registry-to-registry
   copy. Source it from your own image mirror, which already has it from the
   pre-pull, so this step needs no internet either (Docker Hub is rate-limited at the
   venue — that is the whole reason the mirror exists). Which mirror depends on your
   substrate (`cat ~/.cloudbox/substrate`):

   ```bash
   MIRROR=localhost:5001                 # docker / kind: the cloudbox-mirror container
   if [ "$(cat ~/.cloudbox/substrate)" = tbx ]; then
     # tbx: talos-box's own docker.io listener on your cluster gateway (172.30.<n>.1)
     MIRROR="$(tbx status cloudbox -o json | jq -r '.[0].subnet | sub("\\.0/24$"; ".1")'):5055"
   fi

   # --platform: ONE architecture — the NODES' (node_arch asks the substrate: the
   # host CPU on tbx, the Docker daemon on docker; a Rosetta shell's uname lies).
   # On tbx the warmed store only holds that arch's blobs, so a full-index copy
   # would reach for the internet.
   NODE_ARCH="$(bash -c 'SCRIPT_DIR="$1/scripts"; source "$1/scripts/lib.sh" >/dev/null 2>&1; node_arch' _ "$(git rev-parse --show-toplevel)")"
   mise x crane@0.21.9 -- crane copy --insecure --platform "linux/${NODE_ARCH}" \
     "${MIRROR}/library/busybox:1.37.0" zot.cloudbox.k8s.test/library/busybox:1.37.0
   ```

   This works the same on tbx: the mirror speaks plain HTTP, `crane --insecure` tries
   HTTPS first, gets an immediate non-TLS answer (~10 ms) and falls back to HTTP. Nothing
   in module 07 needs the internet on either substrate. If `crane` instead sits repeating
   `net/http: TLS handshake timeout`, the mirror's listener accepted the connection but
   nothing answered — that is a stalled `tbxd`, not the mirror design: check
   `curl -m5 http://<gateway>:5055/v2/` and `tbx system status`, and
   `tbx system restart` if the daemon is wedged (randax/talos-box#498 tracks the
   observability gap).

   If the mirror isn't reachable on any substrate, `docker.io/library/busybox:1.37.0`
   is always a valid source — but then you're online.

   **If that copy hangs** — no output, no error, just nothing — do not wait it out.
   `crane` probes HTTPS before HTTP, and a registry that accepts the connection
   without answering leaves it retrying `net/http: TLS handshake timeout` with
   nothing on screen. Ctrl-C and give it a deadline, so a bad source fails in
   seconds instead of eating the module:

   ```bash
   # same copy, but it gives up instead of hanging (issue #215)
   ( mise x crane@0.21.9 -- crane copy --insecure --platform "linux/${NODE_ARCH}" \
       "${MIRROR}/library/busybox:1.37.0" zot.cloudbox.k8s.test/library/busybox:1.37.0 & \
     pid=$!; ( sleep 45; kill "$pid" 2>/dev/null ) & wait "$pid" ) \
     || echo "the mirror did not answer — use docker.io/library/busybox:1.37.0 as the source instead"
   ```

   That's the platform-team move: you decide what base images exist in your cloud.
4. Submit a build with [`workflow-run.yaml`](workflow-run.yaml) and follow it to
   `Succeeded`. Then prove the artifact is real: ask Zot's API what's in the registry
   (at `http://zot.cloudbox.k8s.test`, using standard OCI `/v2/` endpoints).
5. Run the image: deliver [`hello-site.yaml`](hello-site.yaml) via GitOps, then curl the
   page it serves.
6. Run `./verify.sh`.

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

If it fails immediately with a parameter error, the template's inputs may differ — read
them: `kubectl -n builds get workflowtemplate build-and-push -o yaml | head -40`.

If the *build step* fails resolving `zot.zot.svc.cluster.local:5000/library/busybox` —
did you seed the base image (task step 3)? Check with
`curl -s http://zot.cloudbox.k8s.test/v2/library/busybox/tags/list`.
</details>

<details>
<summary>Hint 2: Interrogating Zot</summary>

Zot speaks the plain OCI registry API:

```bash
curl -s http://zot.cloudbox.k8s.test/v2/_catalog | jq .
curl -s http://zot.cloudbox.k8s.test/v2/hello-site/tags/list | jq .
```

Zot also has a small web UI at `http://zot.cloudbox.k8s.test`.
</details>

<details>
<summary>Hint 3: The deployment can't pull the image?</summary>

Mind the two vantage points: the *build* pushed to `zot.zot.svc.cluster.local:5000`
(cluster DNS — pods can resolve that), but the *node* pulls via NodePort 30500
(node-side),
where cluster DNS doesn't exist. *You* reach Zot at `http://zot.cloudbox.k8s.test`.
If the pull fails: first confirm the image exists in Zot
(hint 2), then `kubectl -n demo describe pod` and read the exact pull error.
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
# from your own mirror — same MIRROR selection as step 3, one platform
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

## Check your work

```bash
./verify.sh
```

It checks: zot and argo-workflows apps Healthy (Synced is the happy path; sync is advisory); Zot's API answering at `http://zot.cloudbox.k8s.test`;
at least one `build-hello-site-*` workflow **Succeeded**; the `hello-site` image present
in Zot's catalog; and the hello-site Deployment Available and serving the page.

## Explain-back

Tell your neighbor: list every network hop in your pipeline (git clone from ? → build
runs where? → push to ? → kubelet pulls from ?). How many of those left your laptop?
That's the sovereignty argument in one answer.

## Going deeper

- **Rebuild `:v1` and watch nothing happen.** Change `app/index.html` and push it to
  Gitea, because the build clones from there and not from your laptop. Submit the same
  workflow again so it pushes `hello-site:v1` a second time, then refresh the page. Nothing
  changed. Now ask Zot:

  ```bash
  curl -sI http://zot.cloudbox.k8s.test/v2/hello-site/manifests/v1 \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' | grep -i docker-content-digest
  kubectl -n demo get pod -l app=hello-site \
    -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
  ```

  New digest, same tag, and the node still runs the old bytes. Kubernetes defaults a
  non-`:latest` tag to `IfNotPresent`, so an unchanged tag means it never looks again. A tag
  is a lie you tell yourself. A digest is a fact. Module 08's Redeploy mints a fresh tag for
  this reason, and module 10 pins digests for it.

- Change `index.html` (v2!), push to Gitea, build `:v2`, and roll `hello-site` to it via
  git. You've reinvented a release pipeline — how would you trigger the build on push?
  (Gitea has webhooks; Argo has Events. At-home project.)
- Inspect the build pod's securityContext while a build runs. What does
  `--oci-worker-no-process-sandbox` trade away, and why did the `builds` namespace need
  the PSA `privileged` label on a Talos cluster?
- Point the module-06 ksvc at the node-side NodePort 30500 image-pull address — the
  *node* pulls via that NodePort; *you* reach Zot at `http://zot.cloudbox.k8s.test` (the cluster's Knative
  config already skips tag-resolution for the Zot registry names; find that setting in
  `config-deployment`).
