# Scenario 01 — spoiler

**Symptom:** the new `demo-app` ReplicaSet never becomes Ready. Its pods repeatedly
restart with `CrashLoopBackOff`, while pods from the previous ReplicaSet can remain up.

**Root cause:** the release commit changed the `PORT` environment value from a valid
port to `8080-canary`. In the real app, `main()` passes `":" + PORT` to
`http.ListenAndServe`. Go's `net.Listen` rejects that address, `log.Fatal` exits the
process, and every new replica crashes. This is configuration poisoning, not an image
pull failure; the container image was never changed.

The default rolling-update strategy protects some availability here. Because the new
ReplicaSet's pods never become Ready, Kubernetes does not finish scaling down the old
ReplicaSet. After the Deployment's progress deadline elapses, its Progressing condition
becomes false with reason `ProgressDeadlineExceeded`.

**Diagnosis path this teaches:**

1. `kubectl -n demo get all` → the Deployment is stuck and the newest pods are restarting.
2. `kubectl -n demo describe pod <new-pod>` → Events show the repeated restarts and
   `CrashLoopBackOff` backoff.
3. `kubectl -n demo logs <new-pod> --previous` → the Go process reports the listen error
   for `:8080-canary` immediately before exiting.
4. Inspect the configured environment with
   `kubectl -n demo get deploy demo-app -o jsonpath='{.spec.template.spec.containers[0].env}'`.
   `kubectl -n demo rollout history deploy/demo-app` also establishes that a rollout
   recently started.
5. In a clone of `cloudbox/demo-app`, `git log --oneline -3` reveals the suspicious
   release commit; `git show <sha>` proves it changed only `PORT` in
   `deploy/deployment.yaml`.

**Canonical fix:** revert the bad Git commit and push the revert — do not edit the live
Deployment, because ArgoCD will reconcile it back to Git.

```bash
git clone http://localhost:30300/cloudbox/demo-app.git
cd demo-app
git log --oneline -3
git revert <sha>
git push
```

Or run `./restore.sh 1`, which performs that same forward `git revert` workflow.

**Verify the fix:** `./verify.sh` requires both a clean Git manifest and a completed,
stable `demo-app` rollout. The replacement pods must be healthy with no
`CrashLoopBackOff` or accumulating restart count.
