# Module 10: day-2 operations, roll back a bad release

## The goal

`gitops/components/demo/demo-web.yaml` in your `cloudbox/platform` repo contains a
forward revert of the bad release, ArgoCD has reconciled that history into namespace
`demo`, and every `demo-web` replica is healthy. `./verify.sh` proves both the
repository and the live rollout.

## Prerequisites

A stretch module. Needs only the cluster and module 02 (Gitea + ArgoCD and the `demo`
Application). The workload it breaks, `demo-web`, is owned by this lab: the first run
of any `./inject.sh <n>` seeds `gitops/components/demo/demo-web.yaml` (a plain
Deployment + Service on the pre-pulled `helloworld-go` image) into your
`cloudbox/platform` repo, then asks you to wait for ArgoCD and run the same scenario
again to inject the fault. A push to `cloudbox/platform:main` is the deploy trigger
throughout; there is no rebuild step. `cloudbox/demo-app` is not used here and
investigating it is a dead end.

## Why this matters

Bad releases look like routine automation changes, reach Git, and produce symptoms
several layers away. Day-2 work starts by observing the failure, writing a falsifiable
diagnosis, and proving it before acting. The operating model, with or without an AI
agent: the agent gets eyes, Git keeps the hands. Whoever finds the cause, `git revert`
and push is the only durable fix; a live `kubectl edit` is not a repair, because ArgoCD
self-healing restores whatever Git says.

## The setup

| # | Scenario | Flavor |
|---|----------|--------|
| 1 | `01-bad-release-rollback` | a plausible release that crashes every new replica |
| 2 | `02-oomkill-nostart` | a rightsizing commit whose new replicas never start at all |
| 3 | `03-dockerhub-sneaks-in` | a registry-migration commit that breaks nothing today and voids the offline guarantee |

The third is the awkward one on purpose: nothing about it is visibly broken on your
laptop, and it still has to be reverted.

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

Each scenario directory has a `description.md`. That is the spoiler; don't open it
until you have committed to a diagnosis. `fix.sh` is the canonical scripted repair.

## The task

The guided path uses scenario 1; scenarios 2 and 3 follow the same loop with their own
hints. Scenario 3's twist: there is no failure to find, and the observation you need is
of a *healthy* pod.

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

Git-clean and live-healthy are separate assertions, so a live-only fix cannot bypass
the Git-only write path; next to a Git FAIL it names the live symptom it found.

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
> mise errors loudly; older ones exit 0 with empty output, the worst failure mode
> there is.

The image still pulls. Look for configuration that controls what address the Go HTTP
server listens on.
</details>

<details>
<summary>Full solution</summary>

Root cause, evidence chain, and the canonical Git repair:
[scenarios/01-bad-release-rollback/description.md](scenarios/01-bad-release-rollback/description.md).
Mechanically, `./restore.sh 1` reverts and pushes; `./solve.sh` reverts every injected
scenario.
</details>

### Scenario 2: the rollout that never lands

<details>
<summary>Hint 1: Establish the goal from what did not happen</summary>

The app is still serving and nothing is crashing, yet one new `demo-web` pod never
becomes Ready and `kubectl -n demo rollout status deploy/demo-web` never returns. Find
why that pod cannot start, connect it to one Git diff, and repair through a forward
revert.
</details>

<details>
<summary>Hint 2: Notice what evidence is missing</summary>

`RESTARTS` is 0 and `kubectl -n demo logs <new-pod>` gives nothing, not even a previous
state. What does the absence of both tell you about how far the pod got?

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

Evidence chain and canonical repair:
[scenarios/02-oomkill-nostart/description.md](scenarios/02-oomkill-nostart/description.md).
`./restore.sh 2` reverts and pushes; `./solve.sh` reverts every injected scenario.
</details>

### Scenario 3: Docker Hub sneaks in

**Read this before you inject it:** this one does not break your cluster. The pods go
Ready and stay Ready. If you are waiting for a red pod, you will wait forever; that is
the exercise, not a bug.

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

Then explain the pull *time* in that Event: nothing on conference WiFi pulls an 8 MB
image that fast. Which thing you built in modules 00-01 could have answered a
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

Why the pull succeeds (the mirror's own access log as proof) and the canonical repair:
[scenarios/03-dockerhub-sneaks-in/description.md](scenarios/03-dockerhub-sneaks-in/description.md).
`./restore.sh 3` reverts and pushes; `./solve.sh` reverts every injected scenario.
</details>

## Escalate to the agent: beat 1 (flail) → beat 2 (diagnose)

Beyond the hints sits Kagent, the platform's read-only agent, streaming a live
investigation into a "Case file" on the demo component's Console page. The same fault,
worked twice, with one field changed in between. Work at least one scenario by hand
first; that's where the triage muscle memory lives.

Beat 1 runs a real model on your host beside the whole cluster and needs the 32 GB
"comfortable" spec from module 00. On 16 GB, skip straight to beat 2; it costs no extra
RAM.

<details>
<summary>Where the RAM numbers come from (measured 2026-08-18)</summary>

On a 32 GB M1 Max (16 GB inside Colima, all 21 apps and 76 pods running),
`qwen3:1.7b` at this repo's `num_ctx: 16384` costs 3.4 GB (1.4 GiB weights, 1.8 GiB KV
cache); ten investigations took 31-106 s each. That is a deliberate climb-down from
the chart's default `qwen3:4b` at `num_ctx: 64000`, which `ollama ps` reports as
12 GB, 9.0 GiB of it KV cache, and the machine spends the investigation swapping. The
context window, not the weights, was 75% of the footprint. 16384 is a floor, not a
preference: one `k8s_get_events` result on this cluster is ~8.2 k tokens, so 8192
overflows the moment the agent reads one.
</details>

### Enable Kagent and point it at your platform

```bash
git clone http://gitea.cloudbox.k8s.test/cloudbox/platform.git && cd platform && mise trust
cp gitops/catalog/kagent.yaml gitops/apps/
git add gitops/apps/kagent.yaml
git commit -m "enable kagent"
git push
```

Wait for `kubectl -n argocd get application kagent` to report `Synced`/`Healthy`.
Expect `kagent-controller` to CrashLoopBackOff ~3 times on the way there and leave it
alone: it runs its database migration at startup, before `kagent-postgresql` has
endpoints, and went 1/1 within ~40-90 s in rehearsal. Ordering failures self-heal;
configuration failures don't. Still restarting after ~3 minutes? Read the logs.

The ModelConfig defaults to host-side Ollama running `qwen3:1.7b`, reached at whatever
"the host" means on your backend, and that address is already handled for you:

<details>
<summary>How the Ollama host address is set, verified, and what can still go wrong</summary>

"The host" is `host.docker.internal` on the macOS/WSL2 Docker backend, `10.5.0.1`
(`TALOS_SUBNET_GATEWAY`) on native-Linux Docker, and the cluster gateway `172.30.<n>.1`
in a talos-box VM. You do not hand-edit it: `bootstrap-gitops.sh` recorded the address
in configmap `kagent/cloudbox-host` back in module 00, and the `kagent-ollama-host`
PostSync hook patches the ModelConfig with it (the kagent Application
`ignoreDifferences` that one field, so selfHeal leaves the patch alone). Verify:

```bash
kubectl -n kagent get modelconfig default-model-config -o jsonpath='{.spec.ollama.host}{"\n"}'
```

If it is not your host's address, the hook's log says why
(`kubectl -n kagent logs job/kagent-ollama-host -c render-patch`). The same patch by
hand:

```bash
kubectl -n kagent patch modelconfig default-model-config --type merge \
  -p "{\"spec\":{\"ollama\":{\"host\":\"$(kubectl -n kagent get cm cloudbox-host -o jsonpath='{.data.ollama}')\"}}}"
```

Ollama must listen on that address, not only loopback. macOS/WSL2 needs nothing (those
runtimes proxy `host.docker.internal` to the host's loopback; verified under Colima on
2026-08-17). A plain bridge or VM gateway proxies nothing, so start Ollama as
`OLLAMA_HOST=0.0.0.0 ollama serve` (or set it in the systemd unit), and confirm from
inside the cluster before blaming kagent:

```bash
# any pod with a shell will do — the kagent images are distroless, Gitea is not
kubectl -n gitea exec deploy/gitea -c gitea -- wget -qO- \
  "http://$(kubectl -n kagent get cm cloudbox-host -o jsonpath='{.data.gateway}'):11434/api/version"
```

Ollama also needs `qwen3:1.7b` pulled. `cloudbox-init.sh` did that in module 00 if
Ollama was installed then; confirm with `ollama list | grep qwen3` (~1.4 GB;
`ollama pull qwen3:1.7b` if missing).
</details>

### Beat 1: watch the local model flail, and write down how

Inject any scenario (or reuse a live one). In the Console, open **Components → demo**
and click **Open investigation**. For the first two minutes the component reads
Rolling out, not Degraded: a Deployment surges, the old version still serves, and the
console waits for the rollout to stop making progress rather than guess from a ready
count that cannot see the problem. Same trap the agent is about to fall into.

Don't grade it on the right answer; it mostly won't get one. A local ≤4B model issues
tool calls fine and falls off a cliff when an investigation must carry state across
several. **Write down exactly how it fails**: a loop, a hypothesis with no evidence, a
malformed follow-up. That sentence is beat 1's deliverable, same spirit as module 05.

<details>
<summary>Calibration: what qwen3:1.7b did across ten rehearsal runs (2026-08-18)</summary>

It calls tools enthusiastically, 4 to 26 per run, all real, all answered. The failure
is what happens to the evidence afterwards:

- breadth instead of depth: one run issued `k8s_get_resources(all_namespaces=true)`
  nineteen times and never asked the crashing pod for its logs, where the answer is one
  line long;
- it narrates the evidence instead of reading it ("this is a Kubernetes event log,
  here is what each field means") while `demo-web` crashloops;
- it diagnoses its own tooling: one run's entire hypothesis was that a tool call had
  failed and "the issue is likely localized to your environment";
- it addresses things that don't exist (a pod name passed as a Deployment, a `demo`
  pod looked up in `default`), takes `tool error:` back, and carries on as if the call
  had returned.

Roughly one run in ten does land on the real cause (`PORT=8080-canary`). Even then,
read the verdict carefully: that run also asserted "the Service is configured to use
8080-canary", which is false. A correct headline with an invented supporting fact is
the most dangerous output on this page, and finding it is worth more than the
diagnosis.
</details>

> **"The investigation didn't complete"** is the model generating without stopping:
> `kagent-controller` 0.9.12 cuts the A2A stream at a hardcoded 180 s, and a small
> model handed a large tool result runs past it (9,000+ token single turns were
> measured). The ModelConfig's `num_predict: "1200"` bounds each turn; if you removed
> it, put it back.

> **The same run from underneath**, if the Case file isn't enough:
> `kubectl -n kagent logs deploy/k8s-agent -f` shows both the model request
> (`POST http://<your host>:11434/api/chat`) and the tool calls
> (`POST http://kagent-tools.kagent:8084/mcp`). A portal image older than
> cloudbox-portal v0.2.1 cannot read kagent 0.9.12's frames and wrongly reports an
> unrecognized format.

### Beat 2: one `ModelConfig` push, and it actually diagnoses

Beat 2 is this module's documented exception to the offline-after-pre-pull rule, the
one place in the workshop that needs the venue network: small local models genuinely
can't do multi-step triage. If the network is down, beat 1 still works on 32 GB
machines and the scenario path needs no network anywhere.

Sign up for a free [OpenCode Zen](https://opencode.ai/auth) key (module 00 prep). Zen's
free models are labeled "for a limited time"; if they're gone, use the fallback below.

Create the Secret imperatively. An API key is the one thing that never goes in Git, and
`read -s` keeps it out of your shell history:

```bash
read -rsp 'OpenCode API key: ' OPENCODE_API_KEY; echo
kubectl create secret generic kagent-zen -n kagent \
  --from-literal="OPENCODE_API_KEY=$OPENCODE_API_KEY"
unset OPENCODE_API_KEY
```

(Paste nothing and `kubectl` happily creates an empty key that fails later with an
opaque auth error; check `kubectl -n kagent get secret kagent-zen -o jsonpath='{.data}'`
if in doubt.)

Then switch the same ModelConfig, via git, to Zen's OpenAI-compatible endpoint. Pick
whichever model is currently marked free at
[opencode.ai/docs/zen](https://opencode.ai/docs/zen/) (at the time of writing:
`deepseek-v4-flash-free`, `mimo-v2.5-free`, `nemotron-3-ultra-free`):

```bash
cd platform && mise trust   # the same clone from above
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

Wait for ArgoCD to converge, then open a new investigation on the same fault. Same
evidence, same read-only tool server; now the verdict comes with a real hypothesis and
an explicit kill-test. Verify that kill-test against the live cluster yourself, then
fix the fault the only way this module fixes anything: `git revert` and push.

The switch is the platform lesson underneath the model lesson: in rehearsal a one-field
push reached the live ModelConfig within 20 s and kagent rolled a new `k8s-agent` pod.
Git is the write path for the agent's own brain too. (That rehearsal had no Zen key;
the mechanism was proven by switching between two local Ollama models.)

**No Zen key, or the free tier is gone?** Same shape, your own key:
`kubectl create secret generic kagent-byo -n kagent --from-literal="API_KEY=$YOUR_KEY"`,
then `apiKeySecret: kagent-byo` / `apiKeySecretKey: API_KEY` and either
`provider: Anthropic` with a current Claude model and `anthropic: {}`, or
`provider: OpenAI` with a current GPT model and `openAI: {}`. Neither needs `baseUrl`;
that field only redirects the generic OpenAI provider to Zen. Field reference:
[kagent supported providers](https://kagent.dev/docs/kagent/supported-providers).

## Explain-back

Which observation connected the failure to the exact Git diff, and why is reverting Git
safer than a live edit that appears to work? (Scenario 3: why was a green cluster not
evidence the release was good?)

## Going deeper

- Watch `kubectl -n demo get rs,pods -w` during a reinjection: why does the old ReplicaSet remain, and what availability does the rolling update preserve?
- Inspect the Deployment conditions before and after its progress deadline: "available through old replicas" vs "the new rollout succeeded".
- Ask a read-only agent for a diagnosis and the command that would falsify it; keep the revert and push in the human-controlled Git path.
