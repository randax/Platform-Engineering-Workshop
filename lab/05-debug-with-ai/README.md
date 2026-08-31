# Module 05: break it, diagnose it, verify the diagnosis

## The goal

Take at least two injected faults from *symptom* to *verified root cause* to *fix*. For
at least one, write down the diagnosis (yours or an AI agent's), then **prove or
falsify it against the live cluster before acting**. `./verify.sh` confirms every
injected fault is actually fixed.

## Why this matters

Debugging in 2026 usually starts with asking an assistant, and assistants are excellent
at Kubernetes triage while being *confidently wrong* just often enough to hurt. The
skill of the decade is not prompting; it is treating every diagnosis as a hypothesis
and designing the one observation that would kill it. Fair warning: one fault below was
built so the obvious AI answer is plausible and wrong.

## The setup

Four faults, in increasing order of deviousness. Each gets its own namespace
(`faultlab-NN`), so your real platform is never touched.

| # | Scenario | Needs | Flavor |
|---|----------|-------|--------|
| 1 | `01-web-down` | module 01 | a deploy that never comes up |
| 2 | `02-db-stuck` | module 03 (CNPG) | a database frozen mid-birth |
| 3 | `03-db-unreachable` | module 01 | everything healthy, nothing connects |
| 4 | `04-db-flaky` | module 01 | works… sometimes. **The trap.** |

```bash
./inject.sh 1        # start here
./restore.sh 1       # apply the canonical fix / give up gracefully
./restore.sh clean   # delete all fault namespaces when done
```

Each fault dir has `description.md`. **That's the spoiler**; don't open it until you've
committed to a diagnosis.

## The task

For each fault you take on (at least 1 and 4; all four if time allows):

1. `./inject.sh <n>`, then find the *symptom* first (`get all`, logs).
2. **Write down a one-sentence diagnosis** before fixing anything. "The pod can't X
   because Y."
3. **Verify it**: what would you observe on the live cluster if your sentence were
   true? Go observe exactly that. If the observation disagrees, the diagnosis is dead;
   write a new one.
4. Fix it however you like. Re-check the symptom.
5. `./verify.sh` when you're done with all your faults.

### With an AI agent (recommended for at least fault 4)

Give an agent read-only eyes on your cluster and make it do steps 1–2, then *you* do
step 3 on its answer:

```bash
./make-readonly-kubeconfig.sh          # writes ./ai-readonly.kubeconfig (4h token)
KUBECONFIG=$PWD/ai-readonly.kubeconfig claude    # or kubectl-ai, k8sgpt analyze, ...
```

A prompt that works well: *"Something is wrong in namespace faultlab-04. Investigate and
give me: (1) your root-cause hypothesis in one sentence, (2) the exact kubectl commands
whose output would prove it, (3) your confidence."* Then run those commands yourself and
pass verdict. The deliverable is the sentence **"the agent claimed X; I checked Y; the
claim was right/wrong because Z."**

No agent handy? Pair up: one plays "confident AI" from the manifests alone, the other
falsifies against the cluster.

## Check your work

```bash
./verify.sh
```

It grades outcomes per fault namespace; fault 4 gets repeated connection attempts, so a
half-fixed trap still fails.

## Hints

<details>
<summary>Hint 1: A triage order that almost always works</summary>

1. `kubectl -n <ns> get all`: what's *not* green?
2. Pod not Running/Ready → `kubectl describe pod` and read the **Events** bottom-up,
   then `kubectl logs` (add `--previous` after crashes).
3. Pod `Pending` → it's a scheduling/resources/volumes problem, not a code problem.
   Describe it; then follow whatever it references (PVC? node? quota?).
4. Everything green but connections fail → stop staring at pods. Check `endpoints`,
   then DNS, then network policies. Timeout ≠ refused: timeouts smell of policy/firewall,
   refusals smell of "nothing listening there".
</details>

<details>
<summary>Hint 2: Commands for the "network is lying to me" faults</summary>

```bash
kubectl -n <ns> get endpoints <svc>          # who does the Service ACTUALLY route to?
kubectl -n <ns> get pods --show-labels       # do labels match what selectors assume?
kubectl get ciliumnetworkpolicies,netpol -A  # who restricts traffic?
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg monitor --type drop             # watch the datapath drop packets, live
```
</details>

<details>
<summary>Hint 3: How to interrogate an AI agent properly</summary>

Don't ask "how do I fix it?"; you'll get a fix for *its* hypothesis, not necessarily
your cluster. Ask for a falsifiable claim plus the evidence that would prove it. If the
agent proposes a fix that "can't hurt anyway", that's a smell, and one fault here
punishes exactly that reflex. Fixes that don't follow from a verified cause are
superstition with YAML.
</details>

<details>
<summary>Full solution</summary>

The written-out root causes and canonical repairs live in each fault's spoiler:

- [faults/01-web-down/description.md](faults/01-web-down/description.md)
- [faults/02-db-stuck/description.md](faults/02-db-stuck/description.md)
- [faults/03-db-unreachable/description.md](faults/03-db-unreachable/description.md)
- [faults/04-db-flaky/description.md](faults/04-db-flaky/description.md)

Mechanically: `./restore.sh all` applies every canonical fix; `./restore.sh clean`
removes the namespaces.
</details>

## Explain-back

For your favorite fault: what was the first diagnosis on the table, which single
command killed or confirmed it, and what would the fix for the wrong diagnosis have
cost?

## Going deeper

- Re-run fault 4 with your agent given live read access: does that change its answer
  versus manifest-only reasoning?
- Design a fault for your neighbor (same contract: `issue.yaml`, `fix.yaml`,
  `description.md`) that survives their agent's first guess.
- Run `k8sgpt analyze --explain` on a fault namespace and grade it: right cause, right
  evidence, right fix?
