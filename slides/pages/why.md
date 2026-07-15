---
layout: section
---

# What if you can no longer trust your cloud?

<!--
The hook. Don't rush this — it's the emotional core of the day, but it's also only three slides.

Frame it as a 2026 question, not a hypothetical: European organizations are actively re-evaluating their cloud dependencies. Ask for a show of hands: "Who has had a cloud bill surprise? Who has had a compliance discussion about where data physically lives? Who has watched a product they depend on change license or get discontinued?"

Every hand that goes up is a person who already knows why they're here.
-->

---

# Three ways a cloud stops being yours

- **Price** — the bill is a decision you don't make
- **Jurisdiction** — your data, someone else's law
- **Roadmap** — products get discontinued under you

<div class="mt-8 text-xl opacity-80">
None of these are hypothetical. All three happened to real teams recently.
</div>

<!--
Walk each bullet with one concrete beat:

- Price: egress fees, license changes rippling into managed-service pricing, the "we renegotiated your enterprise agreement" email. You don't control it; you absorb it.
- Jurisdiction: for a Norwegian public-sector audience this lands hard — CLOUD Act, Schrems II fallout, data residency requirements. Hans can speak from government experience here.
- Roadmap: the software you depend on can be discontinued or taken proprietary. We'll meet a very concrete example of this in module 03 (the MinIO story) — tease it, don't spoil it.

Transition: "The usual answer is 'that's the price of the cloud'. Today we test a different answer: what if the cloud primitives themselves — managed databases, object storage, self-service APIs — are things you can just... run?"
-->

---
layout: fact
---

# You leave with a cloud<br>on **your** laptop

Still running tomorrow. No account. No bill. No permission.

<style>
/* fact h1 is text-8xl and wraps mid-phrase; size it to break at the br */
h1 { font-size: 3.6rem !important; line-height: 1.25 !important; }
</style>

<!--
The promise slide. One sentence, said slowly:

"At the end of these four hours, your laptop is running a complete cloud platform — Kubernetes, GitOps, databases-as-a-service, S3-compatible storage, a self-service API, a portal — and when you close the lid and go home, it's still yours. No trial account, no free tier, no vendor."

Then the meta-point from our design principles: that running artifact, plus the mental model of how it fits together, is the one thing a YouTube video or an AI assistant cannot give you. That's why this is a workshop and not a talk.

Everything is open source and everything is pinned — the repo will still build this platform in a year.
-->
