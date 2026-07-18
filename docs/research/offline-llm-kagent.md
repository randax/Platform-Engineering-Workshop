# Research: Offline LLM feasibility for Kagent on attendee laptops

Resolves issue [#124](https://github.com/randax/Platform-Engineering-Workshop/issues/124).
Frames the LLM-backend posture decision in [#125](https://github.com/randax/Platform-Engineering-Workshop/issues/125).
Researched 2026-07-18 via parallel web-research agents against primary sources
(kagent.dev docs, kagent GitHub issues, Ollama library pages, BFCL methodology,
LiteLLM docs). Re-verify version/size numbers in late August before pinning.

## Question

Can a locally hosted, pre-pullable LLM (≤8B, tool-calling capable) realistically drive
Kagent through **multi-step day-2 Kubernetes triage** on a workshop laptop, offline?

## Verdict — **offline local model is NOT reliable for the diagnosis exercise; recommend a documented online exception via a shared LiteLLM proxy**

- Kagent *can* be pointed at a local model (Ollama or OpenAI-compatible) in one CRD, and
  small tool-calling models *fit* a 32 GB laptop. **The blocker is quality, not plumbing.**
- Stock ≤8B models are competent at emitting a *single* well-formed tool call but collapse
  on the **multi-turn** loop (`get pods → describe → logs → events → PVC → hypothesis`) that
  a seeded fault requires. This is the exact regime where they score in the single digits.
- The online path — a shared **LiteLLM proxy** in front of GPT-4o-mini / Claude Sonnet with
  per-attendee budget + rate caps — is a **one-line kagent config change**, protects the real
  key, hard-caps spend, and costs **on the order of pennies per attendee session**.
- **Recommended module shape:** default the ModelConfig to a local Ollama model as an
  offline-honest *"watch it flail"* baseline, then switch the same ModelConfig to the hosted
  provider to *"make it actually diagnose."* The small-model weakness becomes the teaching
  point instead of a broken lab — and this keeps the offline-first ethos intact while giving
  #125 a documented online exception for the payoff step.

## 1. Kagent plumbing — local models are a supported, trivial config

Kagent's `ModelConfig` CRD (`apiVersion: kagent.dev/v1alpha2`) supports OpenAI, Anthropic,
Azure OpenAI, Amazon Bedrock, **Ollama**, Gemini, Vertex AI, SAP AI Core, xAI, and a
**BYO OpenAI-compatible** endpoint.
([supported-providers](https://kagent.dev/docs/kagent/supported-providers))

**Local Ollama** — `provider: Ollama`, endpoint under `ollama.host`:

```yaml
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata: { name: llama3-model-config, namespace: kagent }
spec:
  model: llama3
  provider: Ollama
  ollama:
    host: http://ollama.ollama.svc.cluster.local   # or a host-side Ollama URL
```
([ollama provider](https://kagent.dev/docs/kagent/supported-providers/ollama))

**Generic OpenAI-compatible** (Ollama's `/v1`, vLLM, llama.cpp, **LiteLLM**) —
`provider: OpenAI` + `openAI.baseUrl` + a Secret:

```yaml
spec:
  model: gpt-4o-mini
  provider: OpenAI
  apiKeySecret: kagent-my-provider
  apiKeySecretKey: PROVIDER_API_KEY
  openAI:
    baseUrl: "https://my-litellm-proxy:4000/v1"
```
([byo-openai](https://kagent.dev/docs/kagent/supported-providers/byo-openai) ·
[openai](https://kagent.dev/docs/kagent/supported-providers/openai))

**Tool-calling is mandatory.** The Ollama provider page states plainly:
*"As kagent relies on calling tools, make sure you're using a model that allows function
calling."* A non-function-calling model will not work — this is a property of how kagent
agents operate, not the transport.
([ollama provider](https://kagent.dev/docs/kagent/supported-providers/ollama))
The docs stop there: **no published minimum parameter count or capability matrix** — model
selection is left to the operator.

## 2. Small tool-calling models (≤8B) — verified "Tools"-capable on Ollama

All flagged with the **Tools** capability badge on their Ollama library page; sizes are the
default (Q4_K_M) on-disk download.

| Model | Params | Disk (default quant) | ~RAM to run | Source |
|---|---|---|---|---|
| **qwen3:4b** | 4B | **2.5 GB** | ~6–8 GB | [ollama.com/library/qwen3](https://ollama.com/library/qwen3) |
| **llama3.2:3b** | 3B | **2.0 GB** | ~6 GB | [ollama.com/library/llama3.2](https://ollama.com/library/llama3.2) |
| **mistral:7b** (v0.3+) | 7B | **4.4 GB** | ~8 GB | [ollama.com/library/mistral](https://ollama.com/library/mistral) |
| **qwen2.5:7b** | 7B | **4.7 GB** | ~8 GB | [ollama.com/library/qwen2.5](https://ollama.com/library/qwen2.5) |
| **llama3.1:8b** | 8B | **4.9 GB** | ~8 GB | [ollama.com/library/llama3.1](https://ollama.com/library/llama3.1) |
| **qwen3:8b** | 8B | **5.2 GB** | ~8 GB | [ollama.com/library/qwen3:8b](https://ollama.com/library/qwen3:8b) |
| granite3.3:8b · cogito:8b | 8B | 4.9 GB | ~8 GB | [granite3.3](https://ollama.com/library/granite3.3) · [cogito](https://ollama.com/library/cogito) |

Notes:
- **Qwen3** is the model Ollama itself uses in its official tool-calling docs — strongest
  signal of good small-model tool behavior. ([ollama tool-calling](https://docs.ollama.com/capabilities/tool-calling))
- **Mistral 7B** function-calling only exists from **v0.3** onward (the current `latest`);
  older 7B tags lack it. ([mistral](https://ollama.com/library/mistral))
- Sub-3B tags (smollm2, llama3.2:1b, qwen3:0.6b) carry the Tools flag but degrade sharply on
  tool-call reliability — demo-only.
- **Best small-footprint pick: `qwen3:4b` (2.5 GB)** — smallest download that still does
  reasonable multi-step tool calling.

## 3. RAM/disk cost vs the workshop budget — fits 32 GB, squeezes 16 GB

Repo landing zone (docs/STACK.md, PLAN.md): in-cluster stack **≈ 7.5–8 GB**, published spec
**16 GB min (≥10 GB to Docker) / 32 GB recommended, 40 GB free disk**; total idle 13–17 GB.
Ollama's rough guidance: **~8 GB RAM for a 7B, 16 GB for 13B** at Q4; CPU-only works (AVX2)
but a GPU is strongly preferred for usable speed.
([system-requirements summaries](https://localaimaster.com/blog/ollama-system-requirements) —
approximate; the classic figure historically lived in Ollama's README FAQ.)

- **Disk:** +2–5 GB per model, pre-pullable by `cloudbox-init.sh`. Comfortable inside the
  40 GB free-disk spec.
- **RAM, 32 GB laptop:** in-cluster ~8 GB + Docker/OS/browser leaves ~16 GB slack — a 4–8B
  model (weights ~4–6 GB + KV/context) **fits with headroom.**
- **RAM, 16 GB laptop (published minimum):** ≥10 GB is already committed to Docker for the
  cluster, leaving ~6 GB for OS/browser/IDE — **no room for a 4–8B model.** On the minimum
  spec the local LLM does not fit alongside the running stack.
- Run Ollama **on the host beside Docker**, not inside the Talos-in-Docker cluster, so it
  doesn't compete with the cluster's memory allocation. (Kagent reaches it via `ollama.host`.)

**Cost conclusion:** local model is feasible on the 32 GB *recommended* spec, infeasible on
the 16 GB *minimum* spec. Any local-default module must say so honestly.

## 4. Realistic quality — small models flail on multi-step; this is the real blocker

### The single-turn → multi-turn cliff (BFCL)

The Berkeley Function-Calling Leaderboard v3 added *multi-turn, state-based* evaluation
precisely because "real agents don't make a single tool call and stop."
([BFCL v3 methodology](https://gorilla.cs.berkeley.edu/blogs/13_bfcl_v3_multi_turn.html) ·
[paper](https://openreview.net/pdf?id=2GmDdhBdDk))

Multi-turn accuracy (the category that matches day-2 triage), stock instruct models:

| Model | Single-turn AST | **Multi-turn** |
|---|---|---|
| GPT-4o | high (~80–90%) | **~41–48%** |
| Qwen2.5-7B-Instruct | ~80–90% | **~11%** |
| Qwen3-4B | ~80%+ | **~16%** |
| Llama-3.1-8B-Instruct | ~80%+ | **~5%** |

The drop from single-call to multi-turn is **~8–17× for ≤8B models vs ~2× for GPT-4o.** A
seeded fault needs 5–15 chained tool calls — squarely the regime where stock 7–8B models sit
near single-digit success. (τ-bench shows even GPT-4o falls from 61% pass@1 to ~25% pass@8 on
multi-turn — small models are worse and less repeatable.)

*Source-quality note:* BFCL's live tables are JS-rendered and not directly scrapable; the
specific small-model multi-turn figures come from arXiv RL papers (MUA-RL, FunReason-MT and
related) that use BFCL v3 multi-turn as their baseline, cross-checked against the BFCL
methodology blog and paper, plus independent summaries
([KDnuggets](https://www.kdnuggets.com/5-small-language-models-for-agentic-tool-calling),
[emergentmind](https://www.emergentmind.com/topics/bfcl-v3-multi-turn-benchmark)). Treat the
exact percentages as indicative; the **direction and magnitude of the cliff are robust.**
Caveat: a *purpose-fine-tuned* tool model (ToolACE-8B, xLAM-2) can match big models — but that
is not the stock `qwen2.5`/`llama3.2` an attendee pulls, and out of scope for a laptop lab.

### Documented local-Ollama failure modes (primary GitHub issues)

- **Infinite tool-call loops:** Google ADK
  [#81](https://github.com/google/adk-python/issues/81),
  [#3637](https://github.com/google/adk-python/issues/3637) — some model templates
  (e.g. llama3.2) push a function call every turn → infinite loop.
- **Streaming eats tool calls:** Ollama behind OpenAI-compatible providers can return empty
  content + `finish_reason: stop`, losing the tool call; workaround `stream:false` when tools
  present ([opencode #1034](https://github.com/sst/opencode/issues/1034)).
- **Context-window trap:** Ollama defaults to a **2048-token context**, silently truncating;
  agents need 16–24K+, and local models "loop more and retry tool calls, burning context
  faster" — an agent loses its own prior tool outputs mid-diagnosis.
- **Kagent-specific:** [kagent #785](https://github.com/kagent-dev/kagent/issues/785) — a user
  on `ollama/llama3.2` reports the k8s agent can't list namespaces/pods. *Honest caveat:* the
  symptom (`record not found`, 404) reads as a config/wiring bug, closed stale with no model
  guidance — evidence that the local path is **fragile to set up**, not clean proof of
  reasoning failure.

### What maintainers actually recommend

Kagent's own quickstart ModelConfig examples default to **`gpt-4o-mini`** and
**`claude-3-sonnet`** — hosted frontier-class, not local 8B
([openai](https://kagent.dev/docs/kagent/supported-providers/openai) ·
[anthropic](https://kagent.dev/docs/kagent/supported-providers/anthropic)). Tool-calling
roundups place GPT-4o / Claude Sonnet / Gemini at the top for reliable tool use. A public
k8s-agent build-log needed *"~20 iterations to come up with a prompt that leads to the least
hallucinations possible"* with smaller models
([PerfectScale](https://www.perfectscale.io/blog/build-simple-ai-agent-to-troubleshoot-kubernetes)).

**Quality verdict:** expect a stock ≤8B model to occasionally nail the first `kubectl get`,
then loop, drop context, or emit malformed tool JSON on the follow-up steps. It will
**demo-fail unpredictably in front of attendees** — unacceptable as the substrate for the
payoff exercise, acceptable only as a deliberate contrast.

## 5. Online alternative — shared LiteLLM proxy is the pragmatic answer

### Kagent hosted config (creds in a Secret)

```bash
kubectl create secret generic kagent-anthropic -n kagent \
  --from-literal ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
```
```yaml
spec: { model: claude-3-sonnet-20240229, provider: Anthropic,
        apiKeySecret: kagent-anthropic, apiKeySecretKey: ANTHROPIC_API_KEY, anthropic: {} }
```
OpenAI is identical with `provider: OpenAI` / `openAI: {}` / `model: gpt-4o-mini`.

### LiteLLM as a workshop-friendly shared gateway

One OpenAI-compatible endpoint (`/v1/chat/completions`) fronting 100+ providers, with
**virtual keys, budgets, rate limits, and spend tracking**
([litellm docs](https://docs.litellm.ai/docs/) ·
[virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys)). Kagent points at it via
`provider: OpenAI` + `openAI.baseUrl`. Per-attendee capped keys:

```bash
curl 'http://<proxy>:4000/key/generate' -H 'Authorization: Bearer <master-key>' \
  -H 'Content-Type: application/json' \
  -d '{"models":["gpt-4o-mini"],"max_budget":2,"budget_duration":"1d","rpm_limit":20}'
```

This solves both workshop risks: **key security** (the real provider key never leaves the
proxy) and **runaway spend** (a looping agent hits a hard per-key budget/RPM cap). Cost:
needs a Postgres + a `master_key`.

### Cost envelope

Pricing: **GPT-4o-mini $0.15/M in, $0.60/M out**; GPT-4o ≈ $2.50/M in
([openai pricing](https://developers.openai.com/api/docs/pricing)). A k8s-triage session
(~5–15 tool turns, 20k–100k cumulative input) ≈ **<$0.02 on mini, $0.05–0.30 on GPT-4o**;
prompt caching cuts input another 50–90%. **For 20–40 attendees × a few sessions: single-digit
dollars on mini, tens of dollars worst-case on GPT-4o.** A $1–2/day/attendee budget is
comfortable and runaway-proof.

## Implications for issue #125 (LLM-backend posture)

1. **The exercise needs frontier-class reasoning to succeed reliably.** A local ≤8B model
   cannot be the substrate for the seeded multi-step fault without a high demo-failure rate.
2. **Offline-first is preserved by making local the honest default and hosted the upgrade:**
   pre-pull `qwen3:4b` with `cloudbox-init.sh`; ship the module so the ModelConfig starts on
   Ollama (attendees *see* it flail on the multi-step loop), then flip the same ModelConfig to
   a hosted provider via a shared LiteLLM proxy for the "now watch it actually diagnose" step.
3. **Documented online exception (per PRINCIPLES honesty rule):** the payoff step requires
   network + the shared proxy. A failed venue network degrades the module to the local-flail
   demo only — state this in the lab README. This is a genuine exception to the offline-first
   requirement and should be recorded as such in #125.
4. **16 GB laptops:** even the local-flail baseline doesn't fit the local model alongside the
   running stack on the published *minimum* spec — the local path assumes the 32 GB
   *recommended* spec. The hosted path adds ~zero RAM and works on 16 GB.

## Primary sources

- Kagent providers: <https://kagent.dev/docs/kagent/supported-providers> ·
  Ollama <https://kagent.dev/docs/kagent/supported-providers/ollama> ·
  BYO-OpenAI <https://kagent.dev/docs/kagent/supported-providers/byo-openai> ·
  OpenAI <https://kagent.dev/docs/kagent/supported-providers/openai> ·
  Anthropic <https://kagent.dev/docs/kagent/supported-providers/anthropic>
- Kagent issue #785: <https://github.com/kagent-dev/kagent/issues/785>
- Ollama tool-calling: <https://docs.ollama.com/capabilities/tool-calling> · model library
  pages linked inline above
- BFCL v3: <https://gorilla.cs.berkeley.edu/blogs/13_bfcl_v3_multi_turn.html> ·
  <https://openreview.net/pdf?id=2GmDdhBdDk>
- Local-Ollama agent failures: <https://github.com/google/adk-python/issues/81> ·
  <https://github.com/google/adk-python/issues/3637> ·
  <https://github.com/sst/opencode/issues/1034>
- LiteLLM: <https://docs.litellm.ai/docs/> ·
  <https://docs.litellm.ai/docs/proxy/virtual_keys>
- OpenAI pricing: <https://developers.openai.com/api/docs/pricing>
