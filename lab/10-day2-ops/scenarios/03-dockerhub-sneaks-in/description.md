# Scenario 03 — spoiler

**Symptom:** *almost none — and that is the scenario.* The release rolls out, the new
pods go `1/1 Running`, `./verify.sh` reports the live workload confirmed, and the only
thing that is wrong is what the pods are now pulling:

```bash
kubectl -n demo get pods -l app=demo-web \
  -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
# docker.io/knative/helloworld-go@sha256:c2b7412f…
```

`kubectl -n demo describe pod <pod>` shows `Successfully pulled image
"docker.io/knative/helloworld-go@sha256:…" in 265ms`. Nothing crashed, nothing is
`ImagePullBackOff`, and a bad release is live.

**Root cause:** the release commit changed only the image registry host from `ghcr.io`
to `docker.io`; the repository path and digest stayed byte-identical. This workshop's
architecture contract requires every workload image to be pinned, hosted on GHCR, and
pre-pulled by `scripts/cloudbox-init.sh` precisely because Docker Hub is rate-limited at
the venue. See the [root repository guide](../../../../CLAUDE.md).

**Why nothing broke — the part worth understanding.** Two mechanisms hide this commit,
both of them things you built in module 00 and 01:

1. `cloudbox-init.sh` copies every pre-pulled image into `cloudbox-mirror` under its
   **registry-stripped repository path** — `ghcr.io/knative/helloworld-go@sha256:c2b7…`
   is stored as `knative/helloworld-go`, with no record of which registry it came from.
2. `create-cluster.sh` points the nodes' **docker.io** mirror (along with ghcr.io,
   quay.io, registry.k8s.io and the rest) at that same local registry.

So `docker.io/knative/helloworld-go@sha256:c2b7…` resolves to
`GET /v2/knative/helloworld-go/manifests/sha256:c2b7…?ns=docker.io` on your own mirror —
and **hits**. Verified on 2026-08-17 from the mirror's access log while a node pulled the
poisoned reference:

```
"HEAD /v2/knative/helloworld-go/manifests/sha256:c2b7412f…?ns=docker.io" 200 "containerd/v2.2.6"
"GET  /v2/knative/helloworld-go/manifests/sha256:c2b7412f…?ns=docker.io" 200 "containerd/v2.2.6"
"GET  /v2/knative/helloworld-go/blobs/sha256:d17f077a…?ns=docker.io"     200 "containerd/v2.2.6"
```

That is not the documented `skipFallback: false` fallback to the real Docker Hub — the
pull never left your laptop. The mirror is keyed by *path*, so it answers for any
registry host you name. The pull would also succeed with no mirror at all, as long as
there is internet: the same digest exists on Docker Hub.

**So where is the outage?** In the two places your laptop is not:

- Any image whose path is **not** in the mirror. Change a digest, a tag, or a
  repository path along with the registry, and there is nothing local to answer — then
  it is Docker Hub or nothing, on shared conference WiFi, against **one** anonymous
  quota for the whole room (100 pulls / 6 hours, `docs/RESEARCH.md`).
- Any cluster rebuilt without `cloudbox-init.sh`, or any teammate's machine with a
  differently-populated mirror. "Works here" is not a property of the manifest.

This is the honest shape of most registry-policy violations: they do not fail, they
*stop being guaranteed*. The guardrail is therefore not a crashing pod — it is the
repository rule (`verify.sh` requires every `image:` in this manifest to start with
`ghcr.io/`) plus a revert.

**Diagnosis path this teaches:**

1. `kubectl -n demo get pods -l app=demo-web` → healthy. Do not stop here; a green pod
   list is not evidence that the last release was good.
2. `kubectl -n demo get pods -l app=demo-web -o jsonpath='{.items[*].spec.containers[*].image}'`
   → the registry host is now `docker.io`.
3. `kubectl -n demo describe pod <pod>` → the `Pulled` Event shows the docker.io
   reference and a suspiciously fast pull time. Ask **who answered**, not just whether
   it worked.
4. Prove it from the mirror side, on your host:
   `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:5001/v2/knative/helloworld-go/manifests/sha256:c2b7412fbea6f1ef24a0cac60698e88df7ae3c4278e42d0cb34fe7d4b2641bba`
   → `200`. Your mirror carries that path, whatever registry the manifest names, which
   is exactly why the change was invisible.
   (`docker logs cloudbox-mirror | grep helloworld` shows the node's own request, with
   `?ns=docker.io`, if you want it from the node's point of view.)
5. In a clone of `cloudbox/platform`,
   `git log --oneline -3 -- gitops/components/demo/demo-web.yaml` reveals the recent
   registry commit; `git show <sha>` confirms that only the registry host changed.

**Canonical fix:** revert the bad Git commit and push the revert — do not edit the live
Deployment, because ArgoCD will reconcile it back to Git.

```bash
git clone http://localhost:30300/cloudbox/platform.git
cd platform
git log --oneline -3 -- gitops/components/demo/demo-web.yaml
git revert <sha>
git push
```

Or run `./restore.sh 3`, which performs that same forward `git revert` workflow.

**Verify the fix:** `./verify.sh` requires every image reference in
`gitops/components/demo/demo-web.yaml` to start with `ghcr.io/`, requires the manifest to
match this module's baseline byte-for-byte, and requires a completed, stable `demo-web`
rollout. While the commit is present, `verify.sh` says so and reports which live symptom
it found: the mirror-served success above, or a genuine `ImagePullBackOff` if you are on
a machine or network where the pull really does fail. Both are the same verdict — revert.

**Why `cloudbox/demo-app` is a dead end:** it is only Go SOURCE for module 07's
in-cluster build (seeded by `scripts/seed-gitea.sh`). Nothing in Kubernetes syncs it
directly, and it carries no deploy manifests — investigating it will not explain this
symptom.
