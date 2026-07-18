# Module 10 — Day-2 operations: roll back a bad release

## The goal

At the end of this module, `cloudbox/demo-app:main` contains a forward revert of the bad
release, ArgoCD has reconciled that Git history into namespace `demo`, and every
`demo-app` replica is healthy. `./verify.sh` proves both the repository and live rollout.

## Prerequisites and interface contract

This is a stretch module. It expects the cluster module, the GitOps module (module 02),
and the portal module (module 08). Module 10's setup/catalog step must also be enabled:
the `cloudbox/demo-app` repository in your in-cluster Gitea must contain a plain
`apps/v1` Deployment at `deploy/deployment.yaml`, and an ArgoCD Application must sync
that path directly into namespace `demo`.

A push to `cloudbox/demo-app:main` is therefore the deploy trigger; there is no Knative,
BuildKit, or rebuild step in this exercise. If `./inject.sh 1` says it cannot find
`deploy/deployment.yaml`, module 10's day-2 demo app has not been enabled on this cluster.

## Why this matters

Bad releases rarely introduce a manifest labeled `BROKEN`. They look like routine
automation changes, reach Git, and produce symptoms several layers away. Day-2
operations starts by observing the failure, writing a falsifiable diagnosis, and proving
it before acting.

This scenario is the human-only path; no agent is required. The operating model still
applies: **the agent gets eyes; Git keeps the hands**. Whether a human or agent finds the
cause, `git revert` and push is the only durable write path. A live `kubectl edit` is not
a repair—ArgoCD self-healing will restore whatever Git says.

## The setup

| # | Scenario | Needs | Flavor |
|---|----------|-------|--------|
| 1 | `01-bad-release-rollback` | module 10 day-2 setup | a plausible release that crashes every new replica |

```bash
./inject.sh 1        # push the bad release commit
./restore.sh 1       # apply the canonical Git revert / give up gracefully
./restore.sh clean   # revert every currently injected scenario
```

The scenario directory has `description.md`—**that is the spoiler**. Do not open it
until you have committed to a diagnosis. `fix.sh` is the canonical scripted repair.

## The task

1. Run `./inject.sh 1`, then find the first visible symptom in namespace `demo`.
2. Write a one-sentence diagnosis before changing anything: “The new pods crash because
   X changed Y.”
3. Verify or falsify that sentence with live evidence. Follow the pod state to Events,
   logs, the Deployment configuration, rollout history, and finally Git history as needed.
4. Revert the commit that introduced the fault and push the revert to
   `cloudbox/demo-app:main`. Do not edit or patch the live Deployment.
5. Run `./verify.sh` and keep investigating until both Git and the live rollout pass.

## Hints

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
with the last few commits in `cloudbox/demo-app`:

```bash
kubectl -n demo get deploy demo-app \
  -o jsonpath='{.spec.template.spec.containers[0].env}'
kubectl -n demo rollout history deploy/demo-app
git log --oneline -3
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
