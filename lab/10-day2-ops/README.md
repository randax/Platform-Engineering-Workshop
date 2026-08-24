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
git clone http://gitea.cloudbox.k8s.test/cloudbox/platform.git && cd platform && mise trust
git log --oneline -3 -- gitops/components/demo/demo-web.yaml
git show <suspicious-sha>
```

> `mise trust` is not ceremony: the clone carries this repo's `mise.toml`, and mise
> refuses to load an untrusted config — so **every mise-installed tool run from inside
> the clone fails** until you trust it, and `kubectl` is one of those. Recent mise says
> so loudly (`mise ERROR … are not trusted`, exit 1); older ones just **exit 0 with
> empty output**, which is the worst failure mode there is.
> A command that prints nothing and succeeds is the worst failure mode there is.

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
git clone http://gitea.cloudbox.k8s.test/cloudbox/platform.git && cd platform && mise trust
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
git clone http://gitea.cloudbox.k8s.test/cloudbox/platform.git && cd platform && mise trust
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
host, *beside* the whole running cluster. That needs the **32 GB "comfortable" spec from
module 00**. On the **16 GB minimum spec, treat beat 1 as optional** — skip straight to
"Beat 2" below. That is not a lesser path; it costs no extra RAM, and it's the one that
actually fits your machine.

Concretely, measured on 2026-08-18 (32 GB M1 Max, 16 GB of it inside Colima, all 21 apps
and 76 pods running): `qwen3:1.7b` at this repo's `num_ctx: 16384` costs **3.4 GB**
outside the VM — 1.4 GiB of weights and **1.8 GiB of KV cache** — and ten investigations
took **31–106 s** of wall clock each.

That is a deliberate climb-down from the chart's own defaults, and the arithmetic is the
whole reason. The chart ships `qwen3:4b` at `num_ctx: 64000`, which `ollama ps` reports
as **12 GB**: 2.6 GiB of weights and **9.0 GiB of KV cache**. On a 32 GB laptop with a
16 GB Colima VM that leaves about 4 GB for macOS itself, and the machine spends the
investigation swapping. **The weights were never the problem — the context window was
75% of the footprint.** Shrinking it to 16384 gives back 7.2 GiB for free, and 16384 is a
floor rather than a preference: a single `k8s_get_events` result on this cluster is
~8.2 k tokens on its own, so 8192 overflows the moment the agent reads one.

### Enable Kagent and point it at your platform

If you haven't already, turn the capability on the same way as every other one in this
workshop — copy the catalog entry into `gitops/apps/` and push:

```bash
git clone http://gitea.cloudbox.k8s.test/cloudbox/platform.git && cd platform && mise trust
cp gitops/catalog/kagent.yaml gitops/apps/
git add gitops/apps/kagent.yaml
git commit -m "enable kagent"
git push
```

Wait for `kubectl -n argocd get application kagent` to report `Synced`/`Healthy`, then
check what shipped: `kubectl -n kagent get modelconfig default-model-config -o yaml`. It
defaults to host-side Ollama running `qwen3:1.7b`, reached at `host.docker.internal:11434`.

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

Ollama itself needs to be running on your host with `qwen3:1.7b` pulled — `cloudbox-init.sh`
did that during module 00, *if* Ollama was already installed when you ran it; if it wasn't,
the script warned and skipped the pull rather than failing. Confirm before you blame the
cluster:

```bash
ollama list | grep qwen3     # ~1.4 GB; ollama pull qwen3:1.7b if it is missing
```

### Beat 1: watch the local model flail — and write down how

Pick any scenario above and inject it (or reuse one you already have live). In the
Console, open **Components → demo** and click **Open investigation**. Watch the
tool-call log stream.

Worth noticing before you click: for the first two minutes the component reads
**Rolling out**, not Degraded, and there is no Diagnostics panel yet. That is
correct — a Deployment surges, so the previous version is still serving and the
ready count still looks full. The console waits for the rollout to stop *making
progress* before calling it degraded, rather than guessing from a count that
cannot see the problem. It is the same trap the agent is about to fall into.

Don't grade it on whether it gets the right answer — it mostly won't. A local ≤4B model
is fine at *issuing* tool calls and falls off a cliff the moment an investigation has to
**carry state across** several (get → describe → logs → events → hypothesis), which every
real fault requires. **Write down exactly how it fails** — a loop that repeats the same
call, a thread it drops after the third one, a hypothesis stated with no evidence behind
it, a malformed follow-up. That sentence is beat 1's deliverable, not a diagnosis — same
spirit as module 05's "the agent claimed X" exercise.

For calibration, here is what `qwen3:1.7b` did across ten Console investigations on the
rehearsal machine (scenario 1 injected, 2026-08-18). It calls tools *enthusiastically* —
4 to 26 of them per run, all real, all answered. The failure is never "it didn't try";
it is what happens to the evidence afterwards:

- **breadth instead of depth.** One run issued `k8s_get_resources(all_namespaces=true)`
  nineteen times, walking every resource *type* in the cluster — services, pods,
  deployments, configmaps, secrets, pv, pvc, events, nodes — and never once asked the
  crashing pod for its logs, where the answer is one line long;
- **it narrates the evidence instead of reading it.** Verdicts come back as a
  *description of the JSON it just downloaded* ("this is a Kubernetes event log, here is
  what each field means") while `demo-web` is crashlooping the whole time;
- **it diagnoses its own tooling.** One run's entire hypothesis was that a `k8s_get_resources`
  call had failed and "the issue is likely localized to your environment" — a real
  finding about nothing, in place of the fault it was asked about;
- **it addresses things that don't exist** — a pod name passed as a `Deployment`, or a
  `demo` pod looked up in namespace `default` — takes `tool error:` back, and carries on
  as if the call had returned.

Roughly one run in ten it *does* land on the real cause (`PORT=8080-canary`) — it reaches
`k8s_get_pod_logs`, and the answer is right there in the first line of output. Even then,
read the verdict carefully: the run that got it right also asserted that "the Service is
configured to use 8080-canary", which is simply false. **A correct headline with an
invented supporting fact is the most dangerous output on this page**, and finding it is
worth more than the diagnosis. Yours will differ in the details; the shape — real tool
calls, then evidence that goes unread — is the point.

> **If the Case file ends on "The investigation didn't complete"**, that is the model
> generating without stopping: `kagent-controller` 0.9.12 cuts the A2A stream at a
> hardcoded **180 s**, and a small model handed a large tool result will happily run past
> it (runs of 9,000+ tokens in a single turn were measured). The ModelConfig's
> `num_predict: "1200"` is what bounds each turn; if you removed it, put it back.

> **Watching from the agent side.** The Console renders this run — the Case file shows
> `tool_call → tool_result → message → verdict`, with the tool's real output collapsed
> under the one-line read. If you want to see the same run from underneath, or the Case
> file is not available to you, both the model request and the tool call are in one log:
>
> ```bash
> kubectl -n kagent logs deploy/k8s-agent -f
> # POST http://host.docker.internal:11434/api/chat  →  your host model answered
> # POST http://kagent-tools.kagent:8084/mcp        →  a tool call actually happened
> ```
>
> (Until cloudbox-portal v0.2.1 the Console could not read kagent 0.9.12's frames at all
> and reported "the agent responded in a format this console doesn't recognize" — which
> was wrong twice over, since the run had succeeded and the version was the pinned one.
> If you see that message, your portal image predates v0.2.1.)

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
cd platform && mise trust   # the same clone from above, or a fresh `git clone .../cloudbox/platform.git`
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
