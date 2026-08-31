# Module 10: day-2 operations, roll back a bad release

## The goal

`gitops/components/demo/demo-web.yaml` in your `cloudbox/platform` repo contains a
forward revert of the bad release, ArgoCD has reconciled that history into namespace
`demo`, and every `demo-web` replica is healthy. `./verify.sh` proves both the
repository and the live rollout.

## Prerequisites

A stretch module. Needs only the cluster and module 02 (Gitea + ArgoCD and the `demo`
Application). This lab owns the workload it breaks, `demo-web`, a plain
Deployment + Service the first `inject.sh` run seeds into your `cloudbox/platform`
repo. Every deploy is a push to `cloudbox/platform:main`; there is no rebuild step,
and `cloudbox/demo-app` plays no part here; investigating it is a dead end.

## Why this matters

Bad releases look like routine automation changes, reach Git, and produce symptoms
several layers away. Observe the failure, write a falsifiable diagnosis, prove it,
then act. Whoever finds the cause, `git revert` and push is the only durable fix; a
live `kubectl edit` is not a repair, because ArgoCD self-heal restores whatever Git
says.

## The setup

| # | Scenario | Flavor |
|---|----------|--------|
| 1 | `01-bad-release-rollback` | a plausible release that crashes every new replica |
| 2 | `02-oomkill-nostart` | a rightsizing commit whose new replicas never start at all |
| 3 | `03-dockerhub-sneaks-in` | a registry-migration commit that breaks nothing today and voids the offline guarantee |

Scenario 3 is awkward on purpose: nothing is visibly broken, and it still has to be
reverted.

Injecting is always two runs: the first seeds the `demo-web` baseline and stops so
ArgoCD can converge it; the second pushes the bad release.

```bash
./inject.sh 1        # first run: seeds the demo-web baseline, then stops
./inject.sh 1        # second run (after ArgoCD converges): pushes the bad release
./restore.sh 1       # the canonical Git revert / give up gracefully
./inject.sh 2        # same two-run pattern
./restore.sh 2
./inject.sh 3
./restore.sh 3
./restore.sh clean   # revert every currently injected scenario
```

Each scenario's `description.md` is the spoiler; don't open it before committing to a
diagnosis. `fix.sh` is the scripted repair.

## The task

The guided path uses scenario 1; scenarios 2 and 3 follow the same loop with their
own hints.

1. Run `./inject.sh 1` twice as described above (wait for
   `kubectl -n demo rollout status deploy/demo-web` between runs).
2. Find the first visible symptom in namespace `demo`.
3. Write a one-sentence diagnosis before changing anything: "The new pods crash because
   X changed Y."
4. Verify or falsify it with live evidence: pod state, Events, logs, the Deployment,
   rollout history, Git history.
5. Revert the commit that introduced the fault and push to `cloudbox/platform:main`.
   Do not edit the live Deployment.
6. Run `./verify.sh` until both Git and the live rollout pass.

## Check your work

```bash
./verify.sh
```

Git-clean and live-healthy are separate assertions, so a live-only fix cannot pass;
next to a Git FAIL it names the live symptom it found.

## Hints

### Scenario 1: bad release rollback

<details>
<summary>Hint 1: Start with the rollout, not the manifest</summary>

Run `kubectl -n demo get all`. Compare ages and readiness of the Deployment,
ReplicaSets, and pods. Which objects are new, and which old ones did Kubernetes keep?
</details>

<details>
<summary>Hint 2: Follow one new pod from symptom to process output</summary>

Describe a new, restarting pod and read Events bottom-up. Then its last process:

```bash
kubectl -n demo describe pod <new-pod>
kubectl -n demo logs <new-pod> --previous
```

`CrashLoopBackOff` is a retry policy, not the root cause. The line before the process
exits tells you what the application could not do.
</details>

<details>
<summary>Hint 3: Connect the process error to the Git change</summary>

Inspect the Deployment's container environment and recent rollout, then the last few
commits to `gitops/components/demo/demo-web.yaml` in a clone of `cloudbox/platform`
(not `cloudbox/demo-app`):

```bash
kubectl -n demo get deploy demo-web \
  -o jsonpath='{.spec.template.spec.containers[0].env}'
kubectl -n demo rollout history deploy/demo-web
git clone http://gitea.cloudbox.k8s.test/cloudbox/platform.git && cd platform && mise trust
git log --oneline -3 -- gitops/components/demo/demo-web.yaml
git show <suspicious-sha>
```

> `mise trust` is not ceremony: the clone carries this repo's `mise.toml`, and every
> mise-installed tool (including `kubectl`) fails inside an untrusted clone. Recent
> mise errors loudly; older ones exit 0 with empty output.

The image still pulls. Look for configuration that controls what address the Go HTTP
server listens on.
</details>

<details>
<summary>Full solution</summary>

[scenarios/01-bad-release-rollback/description.md](scenarios/01-bad-release-rollback/description.md)
has the evidence chain. `./restore.sh 1` reverts and pushes; `./solve.sh` reverts
everything injected.
</details>

### Scenario 2: the rollout that never lands

<details>
<summary>Hint 1: Establish the goal from what did not happen</summary>

The app still serves and nothing crashes, yet one new `demo-web` pod never becomes
Ready and `kubectl -n demo rollout status deploy/demo-web` never returns. Find why,
connect it to one Git diff, and repair through a forward revert.
</details>

<details>
<summary>Hint 2: Notice what evidence is missing</summary>

`RESTARTS` is 0 and `kubectl -n demo logs <new-pod>` gives nothing, not even a
previous state.

```bash
kubectl -n demo get pods -l app=demo-web
kubectl -n demo get rs
```

A failure with no process output happened before your process existed. Kubernetes
records that class of failure in exactly one place.
</details>

<details>
<summary>Hint 3: Read the Events, then the resource budget</summary>

Describe the stuck pod and read Events bottom-up; the container runtime names the
cause. Then the `web` container's memory allocation in the Git-managed Deployment:

```bash
kubectl -n demo describe pod <new-pod>
kubectl -n demo get deploy demo-web \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="web")].resources}'
git clone http://gitea.cloudbox.k8s.test/cloudbox/platform.git && cd platform && mise trust
git log --oneline -3 -- gitops/components/demo/demo-web.yaml
git show <suspicious-sha>
```

The commit's own message says where its number came from. A memory limit is the budget
your container is *created* inside, not just a cap once it runs.
</details>

<details>
<summary>Full solution</summary>

[scenarios/02-oomkill-nostart/description.md](scenarios/02-oomkill-nostart/description.md)
has the evidence chain. `./restore.sh 2` reverts and pushes.
</details>

### Scenario 3: Docker Hub sneaks in

**Read this first:** this one does not break your cluster; the pods go Ready and stay
Ready. That is the exercise, not a bug.

<details>
<summary>Hint 1: Establish the goal without a symptom</summary>

A release landed and everything is green. Decide what you would have to check to be
sure the release was *safe*, not merely working, then check it, and repair what you
find through a forward revert.
</details>

<details>
<summary>Hint 2: Ask what the pods are running, and who answered</summary>

Compare what the pods were told to pull with what module 00 pre-pulled:

```bash
kubectl -n demo get pods -l app=demo-web \
  -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
kubectl -n demo describe pod <pod> | grep -A2 Pulled
```

Then explain the pull *time* in that Event: 8 MB that fast means it never left your
machine. Which thing you built in modules 00-01 could have answered a
`docker.io` request, and why would it? (On docker,
`curl -s -o /dev/null -w '%{http_code}\n' http://localhost:5001/v2/...` and
`docker logs cloudbox-mirror | tail` are fair game; on tbx the mirror is talos-box's
and keyed by registry, so the answer is the opposite: see the scenario briefing.)
</details>

<details>
<summary>Hint 3: Connect the image reference to the Git-managed manifest</summary>

```bash
kubectl -n demo get deploy demo-web \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
git clone http://gitea.cloudbox.k8s.test/cloudbox/platform.git && cd platform && mise trust
git log --oneline -3 -- gitops/components/demo/demo-web.yaml
git show <suspicious-sha>
```

Only the registry host changed; path and digest are byte-identical. Which of the
workshop's guarantees does that cost, and where does the check that catches it have to
live if the cluster is never going to complain?
</details>

<details>
<summary>Full solution</summary>

[scenarios/03-dockerhub-sneaks-in/description.md](scenarios/03-dockerhub-sneaks-in/description.md)
proves why the pull succeeds, from the mirror's own access log. `./restore.sh 3`
reverts and pushes.
</details>

## Escalate to the agent

Kagent, the platform's read-only agent, can run the same investigation and stream it
into a Case file on the demo component's Console page. Work at least one scenario by
hand first, then follow [KAGENT.md](KAGENT.md): part 1 watches a small local model
flail at your fault while you write down how, part 2 switches the same agent to a
hosted model with one git push and gets a diagnosis worth kill-testing.

## Explain-back

Which observation connected the failure to the exact Git diff, and why is reverting Git
safer than a live edit that appears to work? (Scenario 3: why was a green cluster not
evidence the release was good?)

## Going deeper

- Watch `kubectl -n demo get rs,pods -w` during a reinjection: why does the old ReplicaSet remain, and what availability does the rolling update preserve?
- Inspect the Deployment conditions before and after its progress deadline: "available through old replicas" vs "the new rollout succeeded".
- Ask a read-only agent for a diagnosis and the command that would falsify it; keep the revert and push in the human-controlled Git path.
