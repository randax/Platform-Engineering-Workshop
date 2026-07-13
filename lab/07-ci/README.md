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
   contains it (it was seeded with the whole workshop repo).
3. Submit a build with [`workflow-run.yaml`](workflow-run.yaml) and follow it to
   `Succeeded`. Then prove the artifact is real: ask Zot's API what's in the registry
   (NodePort 30500, standard OCI `/v2/` endpoints).
4. Run the image: deliver [`hello-site.yaml`](hello-site.yaml) via GitOps, then curl the
   page it serves.
5. Run `./verify.sh`.

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
</details>

<details>
<summary>Hint 2: Interrogating Zot</summary>

Zot speaks the plain OCI registry API:

```bash
curl -s http://localhost:30500/v2/_catalog | jq .
curl -s http://localhost:30500/v2/hello-site/tags/list | jq .
```

Zot also has a small web UI on the same port.
</details>

<details>
<summary>Hint 3: The deployment can't pull the image?</summary>

Mind the two vantage points: the *build* pushed to `zot.zot.svc.cluster.local:5000`
(cluster DNS — pods can resolve that), but the *kubelet* pulls from the node, where
cluster DNS doesn't exist — that's why `hello-site.yaml` uses `localhost:30500`
(Zot's NodePort, reached from the node itself; containerd allows plain HTTP for
localhost registries). If the pull fails: first confirm the image exists in Zot
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

kubectl create -f "$WORKSHOP/lab/07-ci/workflow-run.yaml"
kubectl -n builds get workflows -w              # until Succeeded

curl -s http://localhost:30500/v2/_catalog | jq .   # hello-site is there

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

It checks: zot and argo-workflows apps Synced/Healthy; Zot's API answering on :30500;
at least one `build-hello-site-*` workflow **Succeeded**; the `hello-site` image present
in Zot's catalog; and the hello-site Deployment Available and serving the page.

## Explain-back

Tell your neighbor: list every network hop in your pipeline (git clone from ? → build
runs where? → push to ? → kubelet pulls from ?). How many of those left your laptop?
That's the sovereignty argument in one answer.

## Going deeper

- Change `index.html` (v2!), push to Gitea, build `:v2`, and roll `hello-site` to it via
  git. You've reinvented a release pipeline — how would you trigger the build on push?
  (Gitea has webhooks; Argo has Events. At-home project.)
- Inspect the build pod's securityContext while a build runs. What does
  `--oci-worker-no-process-sandbox` trade away, and why did the `builds` namespace need
  the PSA `privileged` label on a Talos cluster?
- Point the module-06 ksvc at `localhost:30500/hello-site:v1` — serverless serving of a
  self-built image (the cluster's Knative config already skips tag-resolution for the
  Zot registry names; find that setting in `config-deployment`).
