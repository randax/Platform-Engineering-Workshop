---
layout: section
---

# You didn't run tools.<br>You built an **IDP.**

<!--
The synthesis section — 3 slides, right before the closing. The whole day was hands-on; this names what they actually did. An Internal Developer Platform isn't a product you buy; it's a set of design choices, and they just made every one of them.

Frame it: "Everything you built today — the console, the self-service API, the sizes, the RBAC — those aren't random features. They're the recognised attributes of a well-designed platform. Let me show you the canon, then show you that you implemented all of it."
-->

---

# What makes a platform a *platform?*

<div class="grid grid-cols-4 gap-3 mt-4">
  <div class="principle"><div class="ico"><span class="svgi i-package"></span></div><div class="name">Platform as a product</div><div class="tie">built around user needs</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-sparkles"></span></div><div class="name">User experience</div><div class="tie">consistent interfaces</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-book-open"></span></div><div class="name">Docs & onboarding</div><div class="tie">shipped with the platform</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-concierge-bell"></span></div><div class="name">Self-service</div><div class="tie">no tickets, no humans</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-brain"></span></div><div class="name">Low cognitive load</div><div class="tie">intent, not implementation</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-puzzle"></span></div><div class="name">Optional & composable</div><div class="tie">use only what you need</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-lock"></span></div><div class="name">Secure by default</div><div class="tie">safe defaults, guardrails</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-cloud"></span></div><div class="name">…on a laptop</div><div class="tie">the thinnest viable one</div></div>
</div>

<div class="mt-5 text-sm opacity-70">The CNCF Platforms White Paper's seven attributes — the vendor-neutral definition.</div>

<!--
These seven are the CNCF Platforms White Paper's "attributes" — what separates a platform from just another internal tool. Don't read them out; let the room scan the grid, then make the point: this list is vendor-neutral canon (CNCF), and it traces straight back to Team Topologies — platform-as-a-product, and the insight that a platform's PRIMARY job is to reduce cognitive load on the teams using it.

The eighth card is our addition and the day's punchline: Team Topologies' "Thinnest Viable Platform" — the smallest thing that still counts as a real platform. Ours runs on a laptop.

Say the distinction that keeps this from being buzzword bingo: these are PRODUCT qualities — what the platform is like to use. They sit above the mechanics you also learned (GitOps, immutable infra, operators). A good IDP needs both lenses.
-->

---

# …and today you built every one

<div class="grid grid-cols-2 gap-x-8 gap-y-2 mt-4 text-sm">
  <div><span class="svgi i-package"></span> <b>Product</b> → the Console — a front door you can read</div>
  <div><span class="svgi i-brain"></span> <b>Cognitive load</b> → <code>size: small</code>, not 12 DB fields</div>
  <div><span class="svgi i-sparkles"></span> <b>UX</b> → one console over every capability</div>
  <div><span class="svgi i-puzzle"></span> <b>Composable</b> → enable from a catalog; kubectl still works</div>
  <div><span class="svgi i-book-open"></span> <b>Onboarding</b> → the labs, hints, locked-page teasers</div>
  <div><span class="svgi i-lock"></span> <b>Secure default</b> → "you hand the portal its keys" (RBAC)</div>
  <div><span class="svgi i-concierge-bell"></span> <b>Self-service</b> → New Database / New Function forms</div>
  <div><span class="svgi i-cloud"></span> <b>Thinnest viable</b> → all of it, on your laptop</div>
</div>

<div class="mt-6 text-xl opacity-85">
A shopping list of things you'd <span style="color:var(--jz-rent)">rent</span> — assembled into a platform you <span style="color:var(--jz-run)"><b>own</b></span>.
</div>

<!--
The payoff: every abstract attribute, mapped to something concrete they built with their own hands. Walk a few — "self-service? that's the New Database form. Low cognitive load? that's T-shirt sizing — you asked for 'small', not twelve CNPG fields. Secure by default? that's the RBAC grant where YOU handed the portal its keys."

The take-home sentence — the transferable skill, the thing they carry to work Monday even if they never touch Talos again: an IDP is a set of design choices, not a product you buy, and you now know all seven. The tools change; these don't.

(Grounded in docs/IDP-PRINCIPLES.md — CNCF Platforms White Paper + Team Topologies.)
-->
