---
layout: section
transition: view-transition
---

<span class="badge">Module 05 · core</span>

# Break it. Diagnose it. **Verify** the diagnosis.

<div class="story"><span class="tag">BRUKTBY</span> &nbsp;A listing won't load. Debug their stack like an SRE, and fact-check the AI that hands you a confident, wrong fix.</div>

<!--
The last core module, and the one designed for 2026: debugging on a live system, with or without an AI agent, treating every diagnosis as a hypothesis until the cluster confirms it.
-->

---

# Diagnosis is a hypothesis

- Symptom first, then causes
- Write the diagnosis down. One sentence
- Ask: what observation would **kill** it?
- Go observe. Cluster wins every argument
- Same rule for humans and agents

<!--
The philosophy slide. Installing things teaches less per minute than debugging things. That's why fault injection is a core module, not an optional extra.

The loop we're drilling:
1. Find the SYMPTOM first (get all, logs) before hunting causes.
2. Write down a one-sentence diagnosis, literally write it: "the pod can't X because Y". Unwritten diagnoses mutate to fit whatever you find next.
3. Before fixing anything, ask: if this sentence were true, what exactly would I observe on the live cluster? Design the observation that would falsify it.
4. Go observe. If reality disagrees, the diagnosis is dead; write a new one. This loop IS the module.

Four faults, escalating deviousness, each in its own faultlab-NN namespace so the real platform is never at risk: a deploy that never comes up, a database frozen mid-birth, everything-healthy-nothing-connects, and "works... sometimes."

Verify against the running system, never against text. That's design principle #6, and it applies equally to your own hunches and to anything an agent tells you.
-->

---

# The trap is real

- In 2026, debugging starts with an agent
- Agents are great at K8s triage…
- …and *confidently wrong* just often enough
- Fault 4 was built so the obvious answer is wrong
- Deliverable: "agent claimed X; I checked Y; verdict Z"

<!--
The AI segment. Recommended flow for at least fault 4: run make-readonly-kubeconfig.sh to give an agent read-only eyes on the cluster (a 4-hour token), then point Claude Code / kubectl-ai / k8sgpt at the fault namespace.

The prompt pattern that works, from the lab README: "Investigate namespace faultlab-04 and give me (1) your root-cause hypothesis in one sentence, (2) the exact kubectl commands whose output would prove it, (3) your confidence." Then the HUMAN runs those commands against the real cluster and passes verdict.

Fault 4 is engineered so the obvious AI diagnosis is plausible AND wrong; don't reveal how. The deliverable is not the fix; it's the sentence "the agent claimed X; I checked Y; the claim was right/wrong because Z." Verification of agent output is the 2026 skill, and this is a rep of it.

No agent handy? Pair up: one person plays "confident AI" and states a diagnosis from the manifests alone; the other falsifies it against the cluster. Same muscle.

Spoiler hygiene: each fault dir has description.md. That IS the spoiler; don't open it until you've committed to a diagnosis in writing.
-->

---

# GO: Module 05

**Outcome:** faults 1 + 4 from symptom → verified cause → fix.

```bash
cd lab/05-debug-with-ai
./inject.sh 1        # then 4; ./verify.sh when done
```

<span class="badge">15 min</span> · write the diagnosis **before** the fix

<!--
The task: faults 1 and 4. inject.sh N seeds the fault; restore.sh N applies the canonical fix if you give up gracefully; restore.sh clean removes all fault namespaces afterwards.

House rule to repeat once more: one-sentence written diagnosis BEFORE any fix, then verify it against the cluster, then fix however you like: live edit, kubectl apply, agent-generated patch, all fine. verify.sh confirms every injected fault is actually fixed.

For fault 4, strongly nudge the agent-assisted path (or the pair version). Budget guidance: ~8 minutes on fault 1, the rest on fault 4.

Wrap-up moment worth saying from the front: "In five modules you built a cloud: an OS layer, GitOps delivery, data services, a self-service API. Then you debugged it like an SRE. Two modules left together: serverless, and then the thing it all adds up to."

Then straight into module 06. The platform isn't finished until it can scale to zero and run the pipeline on top.

Anyone behind: catch-up.sh 5 (or any earlier module) gets them current in ~2 minutes.
-->
