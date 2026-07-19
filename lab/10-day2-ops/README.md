# Module 10 — Day-2 operations: roll back a bad release

## The goal

At the end of this module, `gitops/components/demo/demo-web.yaml` in your
`cloudbox/platform` repo contains a forward revert of the bad release, ArgoCD has
reconciled that Git history into namespace `demo`, and every `demo-web` replica is
healthy. `./verify.sh` proves both the repository and the live rollout.

## Prerequisites and interface contract

This is a stretch module. Its only prerequisites are the cluster module and the GitOps
module (module 02) — you need Gitea + ArgoCD running and the `demo` Application
(`gitops/apps/demo.yaml`, watching `gitops/components/demo/` in your platform repo) from
module 02 already enabled. Module 10 needs nothing from the build/serverless/portal
stretch modules (06-09).

The workload this module breaks, `demo-web`, is **owned by this lab, not hand-copied by
you**: the first time you run `./inject.sh 1`, `./inject.sh 2`, or `./inject.sh 3`, it seeds
`gitops/components/demo/demo-web.yaml` (a plain Deployment + Service running the same
pre-pulled `ghcr.io/knative/helloworld-go` image module 06 uses — no in-cluster build
required) into your `cloudbox/platform` repo and pushes it, then asks you to wait for
ArgoCD and run the same scenario again to actually inject the fault. A push to
`cloudbox/platform:main` is the deploy trigger throughout — there is no BuildKit or
rebuild step in this exercise.

`cloudbox/demo-app` (the repo `scripts/seed-gitea.sh` seeds from `apps/demo-app`) is
**not** used by this module — it is Go source for module 07's separate in-cluster build
golden path and carries no deploy manifests. If you find yourself investigating it while
working this scenario, that's a dead end (see the scenario's spoiler once you're stuck).

## Why this matters

Bad releases rarely introduce a manifest labeled `BROKEN`. They look like routine
automation changes, reach Git, and produce symptoms several layers away. Day-2
operations starts by observing the failure, writing a falsifiable diagnosis, and proving
it before acting.

These scenarios are the human-only path; no agent is required. The operating model still
applies: **the agent gets eyes; Git keeps the hands**. Whether a human or agent finds the
cause, `git revert` and push is the only durable write path. A live `kubectl edit` is not
a repair—ArgoCD self-healing will restore whatever Git says.

## The setup

| # | Scenario | Needs | Flavor |
|---|----------|-------|--------|
| 1 | `01-bad-release-rollback` | module 02's `demo` Application | a plausible release that crashes every new replica |
| 2 | `02-oomkill-crashloop` | module 02's `demo` Application | a plausible rightsizing commit that OOMKills every replica on a cadence |
| 3 | `03-dockerhub-imagepull` | module 02's `demo` Application | a plausible registry-migration commit that pulls from Docker Hub instead of the GHCR mirror |

```bash
./inject.sh 1        # first run: seeds the demo-web baseline, then stops
./inject.sh 1        # second run (after ArgoCD converges): pushes the bad release commit
./restore.sh 1       # apply the canonical Git revert / give up gracefully
./inject.sh 2        # first run: seeds the same baseline if it is not present
./inject.sh 2        # second run (after ArgoCD converges): pushes the rightsizing commit
./restore.sh 2       # revert the memory-rightsizing commit / give up gracefully
./inject.sh 3        # first run: seeds the same baseline if it is not present
./inject.sh 3        # second run (after ArgoCD converges): pushes the registry commit
./restore.sh 3       # revert the Docker Hub registry commit / give up gracefully
./restore.sh clean   # revert every currently injected scenario
```

The scenario directory has `description.md`—**that is the spoiler**. Do not open it
until you have committed to a diagnosis. `fix.sh` is the canonical scripted repair.

## The task

The guided path below uses scenario 1; scenarios 2 and 3 follow the same observe,
diagnose, prove, and Git-revert loop using their own setup-table commands and hints.

1. Run `./inject.sh 1`. The first run only seeds the `demo-web` baseline and tells you to
   wait for ArgoCD; run it again once `kubectl -n demo rollout status deploy/demo-web`
   reports success, to actually push the bad release.
2. Find the first visible symptom in namespace `demo`.
3. Write a one-sentence diagnosis before changing anything: “The new pods crash because
   X changed Y.”
4. Verify or falsify that sentence with live evidence. Follow the pod state to Events,
   logs, the Deployment configuration, rollout history, and finally Git history as needed.
5. Revert the commit that introduced the fault and push the revert to
   `cloudbox/platform:main`. Do not edit or patch the live Deployment.
6. Run `./verify.sh` and keep investigating until both Git and the live rollout pass.

## Hints

### Scenario 1: bad release rollback

<details>
<summary>Hint 1: Start with the rollout, not the manifest</summary>

Run `kubectl -n demo get all`. Compare the ages and readiness of the Deployment,
ReplicaSets, and pods. Which objects are new, and which old objects did Kubernetes keep?
</details>

<details>
<summary>Hint 2: Follow one new pod from symptom to process output</summary>

Describe a new, restarting pod and read Events bottom-up. Then inspect its last process:

```bash
kubectl -n demo describe pod <new-pod>
kubectl -n demo logs <new-pod> --previous
```

`CrashLoopBackOff` is a retry policy, not the root cause. The line before the process
exits tells you what the application could not do.
</details>

<details>
<summary>Hint 3: Connect the process error to the Git change</summary>

Inspect the Deployment's container environment and recent rollout, then compare them
with the last few commits to `gitops/components/demo/demo-web.yaml` in a clone of
`cloudbox/platform` (**not** `cloudbox/demo-app` — that repo is unrelated Go source for
a different module, see the "Prerequisites" section above):

```bash
kubectl -n demo get deploy demo-web \
  -o jsonpath='{.spec.template.spec.containers[0].env}'
kubectl -n demo rollout history deploy/demo-web
git clone http://localhost:30300/cloudbox/platform.git && cd platform
git log --oneline -3 -- gitops/components/demo/demo-web.yaml
git show <suspicious-sha>
```

The image still pulls. Look for configuration that controls what address the Go HTTP
server listens on.
</details>

<details>
<summary>Full solution</summary>

The complete root cause, evidence chain, rolling-update behavior, and canonical Git
repair are in
[scenarios/01-bad-release-rollback/description.md](scenarios/01-bad-release-rollback/description.md).

Mechanically, `./restore.sh 1` finds the traced release commit, runs `git revert`, and
pushes the new commit. `./solve.sh` reverts every scenario that is currently injected.
</details>

### Scenario 2: OOMKill crashloop

<details>
<summary>Hint 1: Establish the goal from the live cadence</summary>

Find why a `demo-web` container that can be `Running` now keeps restarting, connect that
runtime evidence to one Git diff, and repair it through a forward revert—not a live edit.
</details>

<details>
<summary>Hint 2: Treat the restart count as evidence</summary>

What does the restart **count** tell you that the `CrashLoopBackOff` reason does not?
Watch it for long enough to distinguish a one-off restart from a process that repeatedly
crosses the same failure boundary:

```bash
kubectl -n demo get pods -l app=demo-web -w
```
</details>

<details>
<summary>Hint 3: Connect the previous process state to the resource budget</summary>

Describe one restarting pod and read `Last State`, `Reason`, and `Exit Code`. Then inspect
the `web` container's configured memory allocation in the Git-managed Deployment:

```bash
kubectl -n demo describe pod <pod>
kubectl -n demo get deploy demo-web \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="web")].resources}'
git clone http://localhost:30300/cloudbox/platform.git && cd platform
git log --oneline -3 -- gitops/components/demo/demo-web.yaml
git show <suspicious-sha>
```

Compare the configured memory allocation with what the Go binary actually needs to run
and serve traffic. The current state may be `Running`; the previous terminated state
records why kubelet had to restart it.
</details>

<details>
<summary>Full solution</summary>

The complete OOMKill evidence chain, restart cadence, and canonical Git repair are in
[scenarios/02-oomkill-crashloop/description.md](scenarios/02-oomkill-crashloop/description.md).

Mechanically, `./restore.sh 2` finds the traced rightsizing commit, runs `git revert`, and
pushes the new commit. `./solve.sh` reverts every scenario that is currently injected.
</details>

### Scenario 3: Docker Hub sneaks in

<details>
<summary>Hint 1: Establish the goal from the pull failure</summary>

Find why the new `demo-web` pods cannot start, connect the pull failure to one Git diff,
and repair it through a forward revert—not a live edit.
</details>

<details>
<summary>Hint 2: Distinguish startup from image retrieval</summary>

The image pulled fine in scenarios 1 and 2. What is different about this failure mode
from the start? Does the container have a previous process state or logs at all?
</details>

<details>
<summary>Hint 3: Connect the pull Event to the Git-managed image</summary>

Describe one affected pod and read Events bottom-up. Compare the exact registry and image
string in the pull error with the Deployment and recent Git history:

```bash
kubectl -n demo describe pod <pod>
kubectl -n demo get deploy demo-web \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
git clone http://localhost:30300/cloudbox/platform.git && cd platform
git log --oneline -3 -- gitops/components/demo/demo-web.yaml
git show <suspicious-sha>
```

Pay attention to the registry host as well as the repository path and digest. The
workshop pre-pulls the GHCR reference, not every equivalent registry location.
</details>

<details>
<summary>Full solution</summary>

The complete ImagePullBackOff evidence chain, workshop registry constraint, and canonical
Git repair are in
[scenarios/03-dockerhub-imagepull/description.md](scenarios/03-dockerhub-imagepull/description.md).

Mechanically, `./restore.sh 3` finds the traced registry commit, runs `git revert`, and
pushes the new commit. `./solve.sh` reverts every scenario that is currently injected.
</details>

## Check your work

```bash
./verify.sh
```

The check fails while Git still contains the poisoned value. Once Git is clean, it also
requires the live Deployment rollout to complete and rejects crashlooping or repeatedly
restarting pods. These checks are intentionally separate: a live-only fix cannot bypass
the platform's Git-only write path.

## Explain-back

Tell your neighbor which observation connected the pod's restart loop to the exact Git
diff, and why reverting Git is safer here than editing the live Deployment—even if the
live edit appears to work for a minute.

## Going deeper

- Watch `kubectl -n demo get rs,pods -w` during a reinjection. Explain why the old
  ReplicaSet remains and what availability the rolling-update strategy preserves.
- Inspect the Deployment conditions before and after its progress deadline. Distinguish
  “available through old replicas” from “the new rollout succeeded.”
- Ask a read-only agent for a diagnosis and the command that would falsify it. Give it
  cluster eyes, but keep the revert and push in the human-controlled Git path.
