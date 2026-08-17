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

Work through at least one scenario by hand first — that's where the triage muscle memory
lives. Once you've done that, "Escalate to the agent" below reruns the same kind of
investigation through Kagent, the platform's own read-only agent, in two beats: a fully
offline model that flails, then a one-line `ModelConfig` change that fixes it.

## The setup

| # | Scenario | Needs | Flavor |
|---|----------|-------|--------|
| 1 | `01-bad-release-rollback` | module 02's `demo` Application | a plausible release that crashes every new replica |
| 2 | `02-oomkill-nostart` | module 02's `demo` Application | a plausible rightsizing commit whose new replicas never start at all |
| 3 | `03-dockerhub-sneaks-in` | module 02's `demo` Application | a plausible registry-migration commit that breaks nothing today and voids the offline guarantee |

The three are deliberately different *shapes* of bad release, and the third one is the
awkward one on purpose: **nothing about it is visibly broken on your laptop.** Scenario 1
crashes loudly, scenario 2 stalls the rollout, scenario 3 goes green and still has to be
reverted. Day-2 work includes the class of bad release whose only symptom is that a
guarantee you rely on is gone.

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
diagnose, prove, and Git-revert loop using their own setup-table commands and hints —
with one twist in scenario 3, where step 2 has no failure to find and the observation
you need is of a *healthy* pod. Its hints say so up front.

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

### Scenario 2: the rollout that never lands

<details>
<summary>Hint 1: Establish the goal from what did not happen</summary>

The app is still serving and nothing is crashing, yet the release is not live: one new
`demo-web` pod never becomes Ready and `kubectl -n demo rollout status deploy/demo-web`
never returns. Find why that pod cannot start, connect it to one Git diff, and repair it
through a forward revert—not a live edit.
</details>

<details>
<summary>Hint 2: Notice what evidence is missing</summary>

`RESTARTS` is 0 and `kubectl -n demo logs <new-pod>` gives you nothing — not even a
previous state. What does the *absence* of both tell you about how far the pod got?

```bash
kubectl -n demo get pods -l app=demo-web
kubectl -n demo get rs
```

A failure with no process output happened before your process existed. Kubernetes records
that class of failure in exactly one place.
</details>

<details>
<summary>Hint 3: Read the Events, then the resource budget</summary>

Describe the stuck pod and read Events bottom-up — the container runtime names the cause
in its own words. Then inspect the `web` container's configured memory allocation in the
Git-managed Deployment:

```bash
kubectl -n demo describe pod <new-pod>
kubectl -n demo get deploy demo-web \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="web")].resources}'
git clone http://localhost:30300/cloudbox/platform.git && cd platform
git log --oneline -3 -- gitops/components/demo/demo-web.yaml
git show <suspicious-sha>
```

The commit's own message tells you where its number came from. Ask what that number left
out — a memory limit is the budget your container is *created* inside, not just a cap on
your program once it runs.
</details>

<details>
<summary>Full solution</summary>

The complete evidence chain, the rolling-update behaviour that keeps the app up, and the
canonical Git repair are in
[scenarios/02-oomkill-nostart/description.md](scenarios/02-oomkill-nostart/description.md).

Mechanically, `./restore.sh 2` finds the traced rightsizing commit, runs `git revert`, and
pushes the new commit. `./solve.sh` reverts every scenario that is currently injected.
</details>

### Scenario 3: Docker Hub sneaks in

**Read this before you inject it:** this one does **not** break your cluster. The pods go
Ready and stay Ready. Your job is to find what the release gave away, prove where the
image actually came from, and revert it anyway. If you are waiting for a red pod, you
will wait forever — that is the exercise, not a bug.

<details>
<summary>Hint 1: Establish the goal without a symptom</summary>

A release landed and everything is green. Decide what you would have to check to be sure
the release was *safe*, not merely working, then check it — and repair whatever you find
through a forward revert, not a live edit.
</details>

<details>
<summary>Hint 2: Ask what the pods are running, and who answered</summary>

Compare what the pods were told to pull with what module 00 pre-pulled:

```bash
kubectl -n demo get pods -l app=demo-web \
  -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
kubectl -n demo describe pod <pod> | grep -A2 Pulled
```

Then explain the pull *time* in that Event. Nothing on conference WiFi pulls an 8 MB
image that fast. Which of the things you built in module 00 and 01 could have answered a
`docker.io` request, and why would it answer for a registry it never fetched from?
(`curl -s -o /dev/null -w '%{http_code}\n' http://localhost:5001/v2/...` and
`docker logs cloudbox-mirror | tail` are both fair game.)
</details>

<details>
<summary>Hint 3: Connect the image reference to the Git-managed manifest</summary>

```bash
kubectl -n demo get deploy demo-web \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
git clone http://localhost:30300/cloudbox/platform.git && cd platform
git log --oneline -3 -- gitops/components/demo/demo-web.yaml
git show <suspicious-sha>
```

Only the registry host changed; the path and digest are byte-identical. Work out which of
the workshop's guarantees that costs you, and where the check that catches it has to live
if the cluster is never going to complain.
</details>

<details>
<summary>Full solution</summary>

Why the pull succeeds (with the mirror's own access log as proof), where the outage
actually waits, the workshop registry constraint, and the canonical Git repair are in
[scenarios/03-dockerhub-sneaks-in/description.md](scenarios/03-dockerhub-sneaks-in/description.md).

Mechanically, `./restore.sh 3` finds the traced registry commit, runs `git revert`, and
pushes the new commit. `./solve.sh` reverts every scenario that is currently injected.
</details>

## Escalate to the agent: beat 1 (flail) → beat 2 (diagnose)

Every scenario above has a fourth rung on the escalation ladder, beyond the three hints:
Kagent, the platform's own read-only agent, streaming a live investigation into a "Case
file" on the demo component's page in the Console. This is the module's second half — the
same fault, worked twice, with one field changed in between.

**Say the honest-spec line out loud before you start:** beat 1 runs a real model on your
host, *beside* the whole running cluster. That needs the **32 GB "comfortable" spec from module 00**. On
the **16 GB minimum spec, beat 1 does not fit next to the running stack** — skip straight
to "Beat 2" below. That is not a lesser path; it costs no extra RAM, and it's the one
that actually fits your machine.

Concretely, measured on 2026-08-17 (32 GB Mac, 16 GB of it inside Colima, all 21 apps
running): loading `qwen3:4b` with the ModelConfig's `num_ctx: 64000` cost **~11.5 GiB**
outside the VM — 2.4 GiB of weights and **9 GiB of KV cache** — and one investigation took
**87 s** of wall clock. The weights are small; the context window is what does not fit.

### Enable Kagent and point it at your platform

If you haven't already, turn the capability on the same way as every other one in this
workshop — copy the catalog entry into `gitops/apps/` and push:

```bash
git clone http://localhost:30300/cloudbox/platform.git && cd platform
cp gitops/catalog/kagent.yaml gitops/apps/
git add gitops/apps/kagent.yaml
git commit -m "enable kagent"
git push
```

Wait for `kubectl -n argocd get application kagent` to report `Synced`/`Healthy`, then
check what shipped: `kubectl -n kagent get modelconfig default-model-config -o yaml`. It
defaults to host-side Ollama running `qwen3:4b`, reached at `host.docker.internal:11434`.

**Expect `kagent-controller` to CrashLoopBackOff ~3 times on the way there, and leave it
alone.** It runs its database migration at startup, and it starts before the
`kagent-postgresql` Service has endpoints (`connect: no route to host`), so it dies and
comes back — 1/1 within ~40–90 s in the 2026-08-17 rehearsal. This is a real day-2 texture
worth two minutes of attention: a restart count is not a diagnosis, and *ordering*
failures self-heal in a way *configuration* failures never do. If it is still restarting
after ~3 minutes, then read the logs.

**macOS and WSL2 (Docker Desktop, OrbStack): nothing else to do.** That address already
resolves inside the containers your cluster nodes run in — including through to an Ollama
listening only on `127.0.0.1`, which is its default. Verified on 2026-08-17 under Colima
(`vmType: vz`): a pod resolved `host.docker.internal` to `192.168.5.2` and got
`{"version":"0.32.14"}` back from `/api/version` with no `OLLAMA_HOST` change at all.

**Native Linux Docker has no `host.docker.internal`.** This is the same host-vs-container
addressing problem `cloudbox-mirror` already solved for you in module 00 (see
`mirror_host_endpoint()` in `scripts/lib.sh`), showing up a second time for a second
reason: "the host" means something different depending on how Docker virtualizes your
network, and every capability that needs to reach out of the cluster hits this once. Fix
it the same GitOps way as every other change in this module — one field, in the same
clone:

```bash
$EDITOR gitops/components/kagent/kagent.yaml   # find `kind: ModelConfig`, then `ollama:`
#   host: host.docker.internal:11434   ->   host: 10.5.0.1:11434
git add gitops/components/kagent/kagent.yaml
git commit -m "kagent: Ollama host is the Linux bridge gateway, not host.docker.internal"
git push
```

`10.5.0.1` is `TALOS_SUBNET_GATEWAY` in `scripts/versions.env` — the exact address
`mirror_host_endpoint()` resolves to on native Linux for the same reason.

On native Linux there is a second half to it: the macOS/WSL2 shortcut above works because
those runtimes proxy `host.docker.internal` into the host's loopback, and a plain bridge
does not. An Ollama bound to `127.0.0.1` is unreachable across `10.5.0.1`, so start it as
`OLLAMA_HOST=0.0.0.0 ollama serve` (or set that in its systemd unit) and confirm from
inside the cluster before blaming kagent:

```bash
# any pod with a shell will do — the kagent images are distroless, Gitea is not
kubectl -n gitea exec deploy/gitea -c gitea -- wget -qO- http://10.5.0.1:11434/api/version
```

Ollama itself needs to be running on your host with `qwen3:4b` pulled — `cloudbox-init.sh`
did that during module 00, *if* Ollama was already installed when you ran it; if it wasn't,
the script warned and skipped the pull rather than failing. Confirm before you blame the
cluster:

```bash
ollama list | grep qwen3     # ~2.6 GB; ollama pull qwen3:4b if it is missing
```

### Beat 1: watch the local model flail — and write down how

Pick any scenario above and inject it (or reuse one you already have live). In the
Console, open **Components → demo** — the detail page whose Diagnostics panel is
already showing your broken `demo-web` — and click **Open investigation**. Watch the
tool-call log stream.

Don't grade it on whether it gets the right answer — it mostly won't. `qwen3:4b` is fine
at *one* tool call and falls off a cliff the moment an investigation has to chain several
(get → describe → logs → events → hypothesis), which every real fault requires.
**Write down exactly how it fails** — a loop that repeats the same `kubectl get`, a
thread it drops after the third tool call, a hypothesis stated with no evidence behind
it, a malformed follow-up. That sentence is beat 1's deliverable, not a diagnosis — same
spirit as module 05's "the agent claimed X" exercise.

For calibration, here is what it did on the rehearsal machine (scenario 1 injected,
2026-08-17): **one** real tool call — `k8s_describe_resource` on the Deployment, which
returned fine — and then, instead of calling the logs tool, it *printed* a tool call as
prose: a `<function-call>` block naming pod `demo-web-69dfd9d57c-0`, a pod that does not
exist. It never chained a second call, and closed with "the root cause is likely a failing
application container startup" — the symptom restated as a cause, with nothing behind it.
Yours will differ in the details; the shape (one tool call, then invention) is the point.

> **Known issue, 2026-08-17 — the Console cannot render this run yet.** Against the pinned
> kagent **0.9.12**, "Open investigation" ends in *"Investigation failed — the agent
> responded in a format this console doesn't recognize"*. The message is misleading: your
> kagent version is the pinned one, and the investigation really ran. kagent streams tool
> steps inside A2A `status-update` frames (with `{name, args}` / `{name, response}` data
> parts) and delivers the final answer as an `artifact-update`; the console still expects
> top-level `tool-call` / `tool-result` / `message` frames, so it drops every frame and
> reports an empty stream. Until the console is fixed, watch beat 1 from the agent side —
> the tool calls and the model request are both in one log:
>
> ```bash
> kubectl -n kagent logs deploy/k8s-agent -f
> # POST http://host.docker.internal:11434/api/chat  →  your host model answered
> # POST http://kagent-tools.kagent:8084/mcp        →  a tool call actually happened
> ```
>
> Everything else in this module — the ModelConfig, the agent, the 78 registered tools,
> the model switch in beat 2 — works; it is the console's translation layer that does not.

### Beat 2: one `ModelConfig` push, and it actually diagnoses

Beat 2 is this module's **documented exception to the offline-after-pre-pull rule** —
the one place in the workshop that needs the venue network (decided and recorded in the
module spec: small local models genuinely can't do multi-step triage, and on 16 GB
machines beat 1 doesn't fit at all). If the network is down, beat 1 still works on
32 GB machines, and the module's scenario path needs no network anywhere.

Sign up for a free [OpenCode Zen](https://opencode.ai/auth) key during module 00 prep if
you haven't yet (see that module's README). "Free" here is explicit and time-boxed —
Zen's free models are labeled **"for a limited time."** If they're gone by the time you
read this, skip straight to the fallback paragraph below.

Create the Secret imperatively — an API key is the one thing in this whole workshop that
never goes in Git (and `read -s` below keeps it out of your shell history too):

```bash
read -rsp 'OpenCode API key: ' OPENCODE_API_KEY; echo
kubectl create secret generic kagent-zen -n kagent \
  --from-literal="OPENCODE_API_KEY=$OPENCODE_API_KEY"
unset OPENCODE_API_KEY
```

(The prompt hides what you type. If you paste nothing, `kubectl` happily creates the
Secret with an **empty** key and beat 2 fails later with an opaque auth error — check
with `kubectl -n kagent get secret kagent-zen -o jsonpath='{.data}'` if in doubt.)

Then switch the *same* ModelConfig, via git, to Zen's OpenAI-compatible endpoint. Pick
whichever model is currently marked free at
[opencode.ai/docs/zen](https://opencode.ai/docs/zen/) (at the time of writing:
`deepseek-v4-flash-free`, `mimo-v2.5-free`, `nemotron-3-ultra-free`):

```bash
cd platform   # the same clone from above, or a fresh `git clone .../cloudbox/platform.git`
$EDITOR gitops/components/kagent/kagent.yaml   # find `kind: ModelConfig`, replace spec:
```

```yaml
spec:
  provider: OpenAI
  model: deepseek-v4-flash-free
  apiKeySecret: kagent-zen
  apiKeySecretKey: OPENCODE_API_KEY
  openAI:
    baseUrl: "https://opencode.ai/zen/v1"
```

```bash
git add gitops/components/kagent/kagent.yaml
git commit -m "kagent: switch beat 2 to OpenCode Zen"
git push
```

Wait for ArgoCD to converge (`kubectl -n argocd get application kagent`), then open a new
investigation on the same fault (if you skipped beat 1, inject any scenario from the
setup table first). Same evidence, same read-only tool server — now the
verdict comes with a real hypothesis and an explicit kill-test. Verify that kill-test
against the live cluster yourself, then fix the fault the only way this module ever fixes
anything: `git revert` and push.

The switch itself is fast and observable, which is the platform lesson underneath the
model lesson: on 2026-08-17 a one-field push reached
`kubectl -n kagent get modelconfig default-model-config -o jsonpath='{.spec.model}'`
**within 20 s**, and kagent rolled a new `k8s-agent` pod to pick it up — the same
git-is-the-write-path mechanic as every scenario above, applied to the agent's own brain.
(What that rehearsal could not check was Zen's endpoint itself — no key. The mechanism was
proven by switching between two *local* Ollama models and watching the second one answer.)

**No Zen key, or the free tier is gone?** Same shape, your own key. Create the Secret the
same way (`kubectl create secret generic kagent-byo -n kagent --from-literal="API_KEY=$YOUR_KEY"`
— one line, quoted), then set `apiKeySecret: kagent-byo` / `apiKeySecretKey: API_KEY` in
the ModelConfig and either `provider: Anthropic` with a current Claude model and
`anthropic: {}`, or `provider: OpenAI` with a current GPT model and `openAI: {}` — no
`baseUrl` needed for either; that field only exists to redirect the generic OpenAI
provider at Zen's endpoint instead of OpenAI's own. Full field reference:
[kagent supported providers](https://kagent.dev/docs/kagent/supported-providers).

## Check your work

```bash
./verify.sh
```

The check fails while Git still contains the poisoned value, and next to that FAIL it
prints which live symptom it found — a `CrashLoopBackOff` (1), a pod the runtime refuses
to start (2), or, for scenario 3, a perfectly healthy pod running a `docker.io/`
reference. It never asks you to wait for a symptom that cannot arrive.

Once Git is clean, it separately requires the live Deployment rollout to complete and
rejects crashlooping, OOMKilled or repeatedly restarting pods across a short stability
window. Git-clean and live-healthy are deliberately separate assertions: a live-only fix
cannot bypass the platform's Git-only write path.

## Explain-back

Tell your neighbor which observation connected the failure to the exact Git diff, and why
reverting Git is safer here than editing the live Deployment—even if the live edit appears
to work for a minute. If you ran scenario 3, tell them instead why a green cluster was not
evidence that the release was good.

## Going deeper

- Watch `kubectl -n demo get rs,pods -w` during a reinjection. Explain why the old
  ReplicaSet remains and what availability the rolling-update strategy preserves.
- Inspect the Deployment conditions before and after its progress deadline. Distinguish
  “available through old replicas” from “the new rollout succeeded.”
- Ask a read-only agent for a diagnosis and the command that would falsify it. Give it
  cluster eyes, but keep the revert and push in the human-controlled Git path.
