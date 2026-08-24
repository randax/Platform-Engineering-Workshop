---
layout: section
---

# The last hour is **yours**

## Pick a door

<!--
The choose-your-own-adventure pivot (~5 min of framing, then the room disperses). The core platform is built and debugged — modules 00–05 are done. From here there is no single path, because the room didn't come for a single reason.

Frame the contract honestly: these are briefings, not labs. No verify.sh, no canonical solution, no "done". Each door has a warm-up with a guaranteed win in ~15 minutes, then an escalating build that is deliberately bigger than the hour — the platform goes home with you, and the briefing is designed to still make sense on the couch.

Point at the helpers: each briefing has a "Known traps" section, and the helpers have read them. The supportable question is "what am I about to trip on?", not "what's the answer?".
-->

---

# Five doors

<div class="grid grid-cols-1 gap-2 mt-2">
  <div v-click class="story"><span class="tag">0 · MARKED TRAIL</span> &nbsp;<Logo name="knative" size="1.2rem"/> <Logo name="argo-workflows" size="1.2rem"/> <Logo name="cloudbox" size="1.2rem"/> <Logo name="grafana" size="1.2rem"/> &nbsp;The guided finale — rehearsed, hinted, verified.</div>
  <div v-click class="story"><span class="tag">1 · APP DEV</span> &nbsp;<Logo name="crossplane" size="1.2rem"/> <Logo name="nats" size="1.2rem"/> <Logo name="buildkit" size="1.2rem"/> &nbsp;Be the product team: one-YAML deploys, event consumers, your own CI.</div>
  <div v-click class="story"><span class="tag">2 · PLATFORM</span> &nbsp;<Logo name="cert-manager" size="1.2rem"/> <Logo name="strimzi" size="1.2rem"/> <Logo name="kafka" size="1.2rem"/> &nbsp;Be the platform team: author a capability — cert-manager (16 GB) or Kafka (32 GB) — then make it self-service.</div>
  <div v-click class="story"><span class="tag">3 · SECURITY</span> &nbsp;<Logo name="cilium" size="1.2rem"/> <Logo name="zot" size="1.2rem"/> &nbsp;Zero trust for real: default-deny a live pipeline, earn it back, sign your images.</div>
  <div v-click class="story"><span class="tag">4 · INFRA</span> &nbsp;<Logo name="talos" size="1.2rem"/> <Logo name="cilium" size="1.2rem"/> &nbsp;The metal layer: machine-config surgery, etcd snapshots, Gateway API, two workers.</div>
</div>

<div v-click class="mt-4 text-lg opacity-85 text-center">
<code>adventures/</code> in the repo · behind? <code>./scripts/catch-up.sh &lt;module&gt;</code> teleports you
</div>

<!--
Walk each door in one breath, selling the *feeling*, not the tech list:

- Door 0 is for "I want the curated ending" — it's the original stretch modules and it's excellent; fast finishers can walk it AND pick a door.
- Door 1: "what does a platform feel like from above?" The one-YAML deploy is the payoff of everything the room built.
- Door 2: "the meta-skill" — every capability they enabled today by copying a file, they now author. The Kafka tier is honest about cost: it's THE experience of adding a heavyweight operator, eyes open. 16/32 GB tiering is real — say it so nobody on a small machine fights a JVM for an hour.
- Door 3: the most visceral one — you break a working pipeline with one policy and watch Hubble name every flow you severed. DNS first when earning it back (it's in the traps, and half the room will hit it anyway — that's the lesson).
- Door 4: for the people who spent all day wondering about the layer below. Zero new images.

Logistics, said once: prerequisites per door are module numbers; catch-up.sh gets anyone anywhere in ~2 minutes; briefings live in adventures/ in the repo they already have. Nothing needs the venue network except Gateway API CRDs on door 4 (flagged in its traps).

Then let them go. Instructors and helpers circulate by door.
-->
