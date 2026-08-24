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
  <div class="story"><span class="tag">0 · MARKED TRAIL</span> &nbsp;The guided finale: Knative → in-cluster CI → the Console → the Bruktby pipeline → day-2 ops. Rehearsed, hinted, verified.</div>
  <div class="story"><span class="tag">1 · APP DEV</span> &nbsp;Be the product team: ship an app with one <code>Application</code> YAML, subscribe a second consumer to the event mesh, build it with your own CI.</div>
  <div class="story"><span class="tag">2 · PLATFORM</span> &nbsp;Be the platform team: author a catalog capability yourself — cert-manager (16 GB) or Kafka via Strimzi (32 GB) — then make it self-service with an XR.</div>
  <div class="story"><span class="tag">3 · SECURITY</span> &nbsp;Zero trust for real: default-deny the live pipeline, watch it break in Hubble, earn it back least-privilege — then sign your images.</div>
  <div class="story"><span class="tag">4 · INFRA</span> &nbsp;The metal layer: Talos machine-config surgery, etcd snapshots, Gateway API on Cilium, rebuild with two workers.</div>
</div>

<div class="mt-4 text-lg opacity-85 text-center">
<code>adventures/</code> in the repo · behind on modules? <code>./scripts/catch-up.sh &lt;module&gt;</code> teleports you
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
