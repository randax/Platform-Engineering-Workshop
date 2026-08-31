# Module 10 extra: escalate to kagent

Kagent, the platform's read-only agent, streams its investigation into a "Case file"
on the demo component's Console page. You run the same fault twice, changing one field
in between. Work at least one scenario in [README.md](README.md) by hand first.

Part 1 runs a real model on your host beside the whole cluster and needs the 32 GB
"comfortable" spec from module 00. On 16 GB, skip straight to part 2; it costs no
extra RAM.

Nothing on this page is graded; the module's `verify.sh` stops at the scenarios.
That is a deliberate exception to principle 6, "Verify against the running system,
never against text": part 1's deliverable is a sentence you wrote about how the
model failed, and part 2's is a kill-test you ran against the cluster yourself.
Both are principle-8 checkpoints (understanding, not completion) that a script
asserting cluster state cannot grade.

## Enable Kagent and point it at your platform

```bash
cd ~/cloudbox-platform && git pull    # your module-02 clone (see README.md, The setup)
cp gitops/catalog/kagent.yaml gitops/apps/
git add gitops/apps/kagent.yaml
git commit -m "enable kagent"
git push
```

Wait for `kubectl -n argocd get application kagent` to report `Synced`/`Healthy`.
`kagent-controller` CrashLoopBackOffs ~3 times on the way there; leave it alone. It
runs its database migration before `kagent-postgresql` has endpoints and goes 1/1
within ~40-90 s. Still restarting after ~3 minutes? Read the logs.

The ModelConfig defaults to host-side Ollama running `qwen3:1.7b`. The host address is
already handled for you:

<details>
<summary>How the Ollama host address is set, verified, and what can still go wrong</summary>

"The host" is `host.docker.internal` on the macOS/WSL2 Docker backend, `10.5.0.1`
(`TALOS_SUBNET_GATEWAY`) on native-Linux Docker, and the cluster gateway
`172.30.<n>.1` in a talos-box VM. You do not hand-edit it: `bootstrap-gitops.sh`
recorded the address in configmap `kagent/cloudbox-host` in module 02, and the
`kagent-ollama-host` PostSync hook patches the ModelConfig with it (the kagent
Application `ignoreDifferences` that one field, so selfHeal leaves the patch alone).
Verify:

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

Ollama must listen on that address, not only loopback. macOS/WSL2 needs nothing
(those runtimes proxy `host.docker.internal` to the host's loopback). A plain bridge
or VM gateway proxies nothing, so start Ollama as `OLLAMA_HOST=0.0.0.0 ollama serve`
(or set it in the systemd unit) and confirm from inside the cluster:

```bash
# any pod with a shell will do; the kagent images are distroless, Gitea is not
kubectl -n gitea exec deploy/gitea -c gitea -- wget -qO- \
  "http://$(kubectl -n kagent get cm cloudbox-host -o jsonpath='{.data.gateway}'):11434/api/version"
```

Ollama also needs the model, which `cloudbox-init.sh` pulled in module 00 and
`scripts/versions.env` pins as `KAGENT_OLLAMA_MODEL`:

```bash
source scripts/versions.env            # the single place the model is pinned
ollama pull "${KAGENT_OLLAMA_MODEL}"   # ~1.4 GB; a no-op when already present
```
</details>

## Part 1: watch the local model flail, and write down how

Inject any scenario (or reuse a live one). In the Console, open the demo component
and click **Open investigation**. For the first two minutes the component reads
Rolling out, not Degraded: a Deployment surges, the old version still serves, and the
console waits for the rollout to stop progressing rather than guess from a ready
count. Same trap the agent is about to fall into.

Don't grade it on the right answer; it mostly won't get one. A local ≤4B model issues
tool calls fine and loses the thread when an investigation must carry state across
several calls. **Write down exactly how it fails**: a loop, a hypothesis with no
evidence, a malformed follow-up. That sentence is part 1's deliverable.

What to expect: it issues real tool calls, 4 to 26 per run, all answered, and then
loses the thread. It lists resources across the whole cluster instead of asking the
crashing pod for its logs, narrates evidence instead of reading it, or diagnoses its
own tooling. Roughly one run in ten lands on the real cause, and even then check the
supporting facts; a correct headline propped up by an invented detail is the most
instructive outcome this part can hand you.

> **"The investigation didn't complete"** is the model generating without stopping:
> the stream is cut after 180 s, and a small model handed a large tool result runs
> past that. The ModelConfig's `num_predict: "1200"` bounds each turn; if you
> removed it, put it back.

> **The same run from underneath:** `kubectl -n kagent logs deploy/k8s-agent -f`
> shows both the model request (`POST http://<your host>:11434/api/chat`) and the
> tool calls (`POST http://kagent-tools.kagent:8084/mcp`).

## Part 2: one `ModelConfig` push to a hosted model

Part 2 is the workshop's one documented exception to principle 2, "Nothing requires
the internet at runtime": a hosted model needs the network, and it earns the
exception because small local models can't do multi-step triage. If the network is
down, part 1 still works on 32 GB machines and the scenario path needs none.

Sign up for a free [OpenCode Zen](https://opencode.ai/auth) key (module 00 prep). If
the free models are gone, use the fallback below.

Create the Secret imperatively; an API key never goes in Git, and `read -s` keeps it
out of your shell history:

```bash
read -rsp 'OpenCode API key: ' OPENCODE_API_KEY; echo
kubectl create secret generic kagent-zen -n kagent \
  --from-literal="OPENCODE_API_KEY=$OPENCODE_API_KEY"
unset OPENCODE_API_KEY
```

(Paste nothing and `kubectl` creates an empty key that fails later with an opaque
auth error; check `kubectl -n kagent get secret kagent-zen -o jsonpath='{.data}'` if
in doubt.)

Then switch the same ModelConfig, via git, to Zen's OpenAI-compatible endpoint. Pick
a model currently marked free at
[opencode.ai/docs/zen](https://opencode.ai/docs/zen/) (at the time of writing:
`deepseek-v4-flash-free`, `mimo-v2.5-free`, `nemotron-3-ultra-free`):

```bash
# in the same platform clone as above (cd back into it if you left)
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
git commit -m "kagent: switch part 2 to OpenCode Zen"
git push
```

Wait for ArgoCD to converge, then open a new investigation on the same fault. Same
evidence, same read-only tool server; a model that can hold the thread across tool
calls should now return a real hypothesis and an explicit kill-test. Verify that
kill-test against the live cluster yourself, then `git revert` and push.

The one-field push reaches the live ModelConfig within seconds and kagent rolls a new
`k8s-agent` pod: Git is the write path for the agent's own brain too.

**No Zen key?** Same shape, your own key:
`kubectl create secret generic kagent-byo -n kagent --from-literal="API_KEY=$YOUR_KEY"`,
then `apiKeySecret: kagent-byo` / `apiKeySecretKey: API_KEY` and either
`provider: Anthropic` with a current Claude model and `anthropic: {}`, or
`provider: OpenAI` with a current GPT model and `openAI: {}`. Neither needs `baseUrl`;
that field only redirects the generic OpenAI provider to Zen. Reference:
[kagent supported providers](https://kagent.dev/docs/kagent/supported-providers).
