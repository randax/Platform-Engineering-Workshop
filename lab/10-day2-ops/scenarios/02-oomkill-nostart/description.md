# Scenario 02: spoiler

**Symptom:** `kubectl -n demo get pods -l app=demo-web` shows the two old pods still
`1/1 Running` and one new pod stuck at `0/1 ContainerCreating` for minutes, with
`RESTARTS 0` and no logs at all. `kubectl -n demo rollout status deploy/demo-web` never
completes. `kubectl -n demo describe pod <new-pod>` repeats one Event every ~12 seconds:

```
Warning  FailedCreatePodSandBox  kubelet  Failed to create pod sandbox: … runc create
  failed: unable to start container process: container init was OOM-killed
  (memory limit too low?)
```

**Root cause:** the rightsizing commit set the `web` container's memory request *and*
limit to `2Mi`. The limit applies to the whole pod cgroup, and the container runtime's
own `runc init` process has to live inside it before your program is ever executed. At
`2Mi` it gets OOM-killed while setting the container up, so no process of yours ever
starts. Kubelet retries the sandbox forever. Because the *old* ReplicaSet is untouched,
the Deployment stays `Available` on its two old replicas and the rolling update simply
stalls: the app keeps serving while the release is stuck.

**Why the commit looks reasonable:** its message says the observed idle RSS was ~2 MiB
and aligns the request and the limit with it. That is a real number; `helloworld-go`
really does idle in about that much, and it is exactly the reasoning a rightsizing bot
(or a human reading a memory graph) applies. What the number leaves out is the runtime's
own overhead and any headroom for serving traffic. Rightsizing to the *observed idle
floor* is a classic production incident.

**Diagnosis path this teaches:**

1. `kubectl -n demo get pods -l app=demo-web` → the new pod is not Ready, and unlike
   scenario 1 it is not restarting either. `RESTARTS` stays 0.
2. `kubectl -n demo logs <new-pod>` → *no logs, no previous state*. Nothing of yours ran.
   That is the signal: this failure happened **before** the container process existed.
3. `kubectl -n demo describe pod <new-pod>` → read Events bottom-up. The runtime names
   the cause itself: `container init was OOM-killed (memory limit too low?)`.
4. `kubectl -n demo get deploy demo-web -o jsonpath='{.spec.template.spec.containers[?(@.name=="web")].resources}'`
   → `{"limits":{"memory":"2Mi"},"requests":{"cpu":"25m","memory":"2Mi"}}`.
5. `kubectl -n demo get rs` → the old ReplicaSet still has 2 ready replicas, which is why
   nothing is *down*. Distinguish "available through old replicas" from "the new rollout
   succeeded".
6. In a clone of `cloudbox/platform`,
   `git log --oneline -3 -- gitops/components/demo/demo-web.yaml` reveals the recent
   rightsizing commit, and `git show <sha>` confirms it changed only the `web`
   container's memory request and limit, nothing else.

**Canonical fix:** revert the bad Git commit and push the revert. Do not edit the live
Deployment; ArgoCD will reconcile it back to Git.

```bash
cd ~/cloudbox-platform && git pull   # your module-02 clone of cloudbox/platform
git log --oneline -3 -- gitops/components/demo/demo-web.yaml
git revert <sha>
git push
```

Or run `./restore.sh 2`, which performs that same forward `git revert` workflow.

**Verify the fix:** `./verify.sh` requires a clean `gitops/components/demo/demo-web.yaml`
(matching this module's own baseline byte-for-byte), a completed `demo-web` rollout, and
two pod-status samples over a stability window. Neither sample may show
`CrashLoopBackOff` or a previous `OOMKilled` termination, and restart counts must not
increase between samples.

**Why the limit is `2Mi` and not a "plausible" `8Mi`:** because a tight-but-survivable
limit produces no symptom you could wait for. Measured on this stack (containerd 2.2.6 +
runc) on 2026-08-17 with this exact manifest: at `8Mi` both replicas ran Ready with zero
restarts for ten minutes idle, survived 300 sequential requests, and only one replica
OOMKilled after ~4800 concurrent ones. `4Mi` and `6Mi` were still happy. `3Mi` and below
never start. An OOMKill you can only trigger with a load generator is a real production
failure mode but a broken lab, so this scenario teaches the deterministic half of the
same lesson: **a memory limit is not just a cap on your process, it is the budget the
runtime starts your container inside.**

**This is not a crashloop and not an image-pull problem:** there is no process to crash
(scenario 1) and the image pulled fine (scenario 3). `FailedCreatePodSandBox` +
`OOM-killed` is a resource-budget signature and belongs to this scenario only.

**Why `cloudbox/demo-app` is a dead end:** it is only Go SOURCE for module 07's
in-cluster build (seeded by `scripts/seed-gitea.sh`). Nothing in Kubernetes syncs it
directly, and it carries no deploy manifests; investigating it will not explain this
symptom.
