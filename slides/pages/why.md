---
layout: section
---

# What if you can no longer trust your cloud?

<!--
The hook. Don't rush this — it's the emotional core of the day. Three slides, and by the end of them the room has a company to root for.

Frame it as a 2026 question, not a hypothetical: European organizations are actively re-evaluating their cloud dependencies. Ask for a show of hands: "Who has had a cloud bill surprise? Who has had a compliance discussion about where data physically lives? Who has watched a product they depend on change license or get discontinued?"

Every hand that goes up is a person who already knows why they're here. Then: "Let me introduce you to a company that raised all three hands."
-->

---

# Meet Bruktby

<div class="text-xl opacity-90 mt-2">A Norwegian second-hand marketplace — <em>kjøp og selg brukt.</em></div>

<div class="story mt-6">
<span class="svgi i-package"></span> Snap a photo of the thing in your loft → it's a listing in seconds. Someone across the fjord buys it. <strong>Photos in, thumbnails out, listings browsable.</strong> A million small uploads a day.
</div>

<div class="mt-6 text-lg opacity-80">
Version 1 shipped fast on a big US hyperscaler — managed Kubernetes, managed Postgres, managed object storage, a serverless thumbnailer. It worked. Then three bills came due.
</div>

<!--
Introduce the protagonist you'll carry all day. Bruktby (brukt = second-hand, -by = town) is a made-up but utterly ordinary Norwegian marketplace — think Finn.no's little cousin. Keep it concrete and unglamorous: the whole product is "photograph an item, it becomes a listing, people browse and buy." That shape matters, because it is EXACTLY the app the room builds today — an upload → store → resize → gallery pipeline over a Postgres of listings.

Say the v1 story without judgment: shipping on a hyperscaler was the right call to get to market. Managed everything, credit-card sign-up, live in a weekend. This is not a "cloud bad" talk. The turn is that three specific, real forces made "their" cloud stop being theirs — and those three forces are the next slide.

The tagline to plant: "Today, you are Bruktby's platform team. Your job for the next four hours is to rebuild their cloud on infrastructure they own."
-->

---

# Three bills came due

<div class="grid grid-cols-1 gap-3 mt-2">
  <div class="story"><span class="tag">PRICE</span> &nbsp;Every listing photo is stored, then re-served on every browse. Storage + egress became Bruktby's biggest line item — and the renewal email wanted more.</div>
  <div class="story"><span class="tag">JURISDICTION</span> &nbsp;A big B2B partner asked one question: <em>can you prove our users' data never leaves Norway?</em> Post-Schrems II, "EU region" wasn't an answer.</div>
  <div class="story"><span class="tag">ROADMAP</span> &nbsp;The managed object-store they built on got <strong>relicensed</strong> out from under them. The floor moved. (You'll meet this one for real in module 03.)</div>
</div>

<div class="mt-6 text-xl opacity-80">
Price. Jurisdiction. Roadmap. None hypothetical — all three hit Bruktby, and none of them were theirs to control.
</div>

<!--
These are the three ways ANY cloud stops being yours, told through Bruktby so they land as a story, not a lecture:

- Price: the bill is a decision you don't make. For an image-heavy app it's brutal — you pay to store every photo and pay again in egress every time someone scrolls the listings. Then the enterprise-agreement renegotiation email arrives. You absorb it; you didn't decide it.
- Jurisdiction: your data, someone else's law. For a Norwegian audience this lands hard — CLOUD Act, Schrems II, Datatilsynet. The B2B-partner framing is the realistic trigger: one procurement questionnaire asks "where does the data physically live?" and "EU region of a US company" no longer passes. Hans can speak from government experience here.
- Roadmap: the software under you can be discontinued or taken proprietary. This is the MinIO story, and it's real — we deliberately tee it up here and pay it off in module 03. Don't spoil the name yet; just plant that the floor can move.

Transition: "The usual answer is 'that's the price of the cloud.' Bruktby tried a different answer — and so will you. What if the cloud primitives themselves — the database, the bucket, the thumbnailer, the self-service API — are things you can just... run?"
-->

---
layout: fact
---

# You leave with Bruktby's cloud —<br>and it's **yours**

Still running tomorrow. No account. No bill. No permission.

<style>
h1 { font-size: 3.4rem !important; line-height: 1.25 !important; }
</style>

<!--
The promise slide, now with a protagonist. Said slowly:

"At the end of these four hours, your laptop is running the complete cloud platform Bruktby moved to — Kubernetes, GitOps, a managed database, S3-compatible storage, a self-service API, serverless, a portal — with their photo pipeline live on top of it. And when you close the lid and go home, it's still yours. No trial account, no free tier, no vendor."

Then the meta-point from our design principles: that running artifact, plus the mental model of how it fits together, is the one thing a YouTube video or an AI assistant cannot give you. That's why this is a workshop and not a talk.

Everything is open source and everything is pinned — the repo will still build Bruktby's cloud in a year. You're not building a demo; you're doing the migration.
-->
