---
layout: section
transition: view-transition
---

# The rest of the day is **yours**

## Pick a door

<!--
The choose-your-own-adventure pivot (~5 min of framing, then the room disperses for 45). The platform is built, debugged, and running the picture pipeline — modules 00–06 and 09 are done. From here there is no single path, because the room didn't come for a single reason.

This also replaces the second break: say plainly that the room is self-paced now and coffee is whenever they want it.

Frame the contract honestly: these are briefings, not labs. No verify.sh, no canonical solution, no "done". Each door has a warm-up with a guaranteed win in ~15 minutes, then an escalating build that is deliberately bigger than the time left — the platform goes home with you, and the briefing is designed to still make sense on the couch.

Say where help lives, honestly: the briefings are self-service by design — two of us cannot staff five doors. Each briefing has a "Known traps" section written to be read before you need it; that section is the first responder, a neighbor on the same door is the second, and whichever of us is on the floor is the third. The supportable question is "what am I about to trip on?", not "what's the answer?".
-->

---

# Five doors

<div class="grid grid-cols-1 gap-2 mt-2">
  <div v-click class="story"><span class="tag">0 · START HERE</span> &nbsp;<Logo name="argo-workflows" size="1.2rem"/> <Logo name="cloudbox" size="1.2rem"/> <Logo name="kagent" size="1.2rem" text="kagent"/> &nbsp;Modules 07 · 08 · 10 — build images in-cluster, read your Console end to end, hand an agent the day-2 pager.</div>
  <div v-click class="story"><span class="tag">1 · APP DEV</span> &nbsp;<Logo name="crossplane" size="1.2rem"/> <Logo name="nats" size="1.2rem"/> <Logo name="buildkit" size="1.2rem"/> &nbsp;Be the product team: one-YAML deploys, event consumers, your own CI.</div>
  <div v-click class="story"><span class="tag">2 · PLATFORM</span> &nbsp;<Logo name="cert-manager" size="1.2rem"/> <Logo name="strimzi" size="1.2rem"/> <Logo name="kafka" size="1.2rem"/> &nbsp;Be the platform team: author a capability — cert-manager (16 GB) or Kafka (32 GB) — then make it self-service.</div>
  <div v-click class="story"><span class="tag">3 · SECURITY</span> &nbsp;<Logo name="cilium" size="1.2rem"/> <Logo name="zot" size="1.2rem"/> &nbsp;Zero trust for real: default-deny a live pipeline, earn it back, sign your images.</div>
  <div v-click class="story"><span class="tag">4 · INFRA</span> &nbsp;<Logo name="talos" size="1.2rem"/> <Logo name="cilium" size="1.2rem"/> &nbsp;The metal layer: machine-config surgery, etcd snapshots, Gateway API, two workers.</div>
</div>

<div v-click class="mt-4 text-lg opacity-85 text-center">
<code>adventures/</code> in the repo · <strong>take door 0 unless you already know which door you want</strong> · behind? <code>catch-up.sh &lt;module&gt;</code> teleports you<br>
<span class="text-sm opacity-75">briefings are self-service — read your door's "Known traps" first · projector demos ~3:20 in-cluster build · ~3:35 Backstage, both optional<br>hard stop 10 min before the end — we close together</span>
</div>

<!--
Walk each door in one breath, selling the *feeling*, not the tech list:

- Door 0 is the recommendation, said plainly and first: "unless you already know which door you want, take door 0." It is the rehearsed, hinted, verified trail — the three modules the guided day didn't cover: your cluster building its own images (07), the Console you've been clicking all day read line by line (08), and an AI agent given the day-2 pager with read-only eyes (10). Anyone who wants a different day should absolutely take another door; door 0 is the answer to hesitation, not a consolation prize.
- Door 1: "what does a platform feel like from above?" The one-YAML deploy is the payoff of everything the room built.
- Door 2: "the meta-skill" — every capability they enabled today by copying a file, they now author. The Kafka tier is honest about cost: it's THE experience of adding a heavyweight operator, eyes open. 16/32 GB tiering is real — say it so nobody on a small machine fights a JVM for an hour.
- Door 3: the most visceral one — you break a working pipeline with one policy and watch Hubble name every flow you severed. DNS first when earning it back (it's in the traps, and half the room will hit it anyway — that's the lesson).
- Door 4: for the people who spent all day wondering about the layer below. Zero new images.

Pitch discipline (researched — decision paralysis is the #1 failure mode of multi-track endings): ≤1 minute per door, sell the feeling not the tech list, and lead with the default rather than ending on it — "door 0 unless you already know what you want; you can switch any time". As you pitch each door, point at its "Known traps" section — that's the door's support, and reading it first is the difference between a good hour and a stuck one.

Scope honesty for door 0, said once: three modules is more than 45 minutes of material. Nobody is expected to finish all of it in the room — like every door, it is written to start here and finish at home, and every module on it has hints, a verify.sh and catch-up.sh behind it.

Logistics, said once: prerequisites per door are module numbers; catch-up.sh gets anyone anywhere in ~2 minutes; briefings live in adventures/ in the repo they already have. Nothing needs the venue network except Gateway API CRDs on door 4 (flagged in its traps).

THE HARD STOP: announce it here and honor it — 10 minutes before the end, one signal, everyone back for the close. An open-ended hour that fizzles into people drifting out is remembered as a fizzle (peak-end rule); the before/after replay in the closing section is what makes four hours land as an achievement. Every door's warm-up delivers a visible win inside ~15 minutes precisely so nobody hits the stop empty-handed.

Then let them go. One presenter anchors the projector — this slide stays up, interrupted only by the two opt-in demos — while the other circulates across doors. That's all the staffing there is; the briefings have to carry themselves, and they're written to.

Deck discipline for the anchor: the module 06–10 pages that follow are door-0 reference, not a section to perform. After this slide, the next slide you PRESENT is the principles section, at the hard stop.
-->
