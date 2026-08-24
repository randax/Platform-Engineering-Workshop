---
layout: section
---

# A cloud is not yet a platform

<!--
Bridge section (~8 min, zero keyboard) between "what is a cloud" and the stack. The table you just showed is a pile of primitives — powerful, and completely undifferentiated. This section names the discipline the workshop actually teaches: platform engineering. And it grounds it in a real, Norwegian, national-scale example — Nav — so nobody leaves thinking today was a laptop trick.

The one-liner to plant: "A cloud gives you primitives. A platform gives you opinions."
-->

---

# Primitives vs. platform

<div class="grid grid-cols-2 gap-6 mt-4">
  <div class="story">
    <h3>A cloud</h3>
    Compute, storage, databases, queues — <strong>as APIs</strong>.<br><br>
    Every team assembles them differently. Every team carries the ops,
    the security, the upgrades. 50 teams → 50 snowflakes.
  </div>
  <div class="story">
    <h3>A platform</h3>
    The same primitives, <strong>pre-composed into paths</strong>.<br><br>
    One way to deploy. Dependencies by declaration. Observability and
    security included, not bolted on. 50 teams → one way that works.
  </div>
</div>

<div class="mt-8 text-xl opacity-85 text-center">
A platform is <strong>opinions about how primitives compose</strong> — and the discipline is making the right thing the easiest thing.
</div>

<!--
Walk it: renting (or building!) a cloud still leaves the hard question — how do fifty teams use it without fifty bespoke architectures? The platform answer is opinionated paths: golden paths. Not a portal, not a wiki, not a ticket queue — a paved road where deploying the right way is *less* work than deploying the wrong way.

Foreshadow: "You'll build both layers today. Modules 01–03 are the cloud. Modules 04, 08 and 09 are the platform — the moment one YAML file gets a team a running app with its database and bucket wired in."
-->

---

# This works at national scale: Nav

<div class="text-lg opacity-90 mt-2">Norway's Labour and Welfare Administration — the services a third of the country depends on — runs on a platform its own engineers built: <strong>Nais</strong> (open source, nais.io).</div>

<div class="grid grid-cols-3 gap-4 mt-6 text-center">
  <div class="story"><div class="text-3xl font-bold">~100+</div>product teams served</div>
  <div class="story"><div class="text-3xl font-bold">1000s</div>of deploys per week</div>
  <div class="story"><div class="text-3xl font-bold">1</div>manifest to production</div>
</div>

<div class="mt-6 text-lg opacity-85">
A team writes one <code>nais.yaml</code> — app, database, bucket, queue, access policy — and the platform does the rest. Sound familiar? It's the shape you build in module 04.
</div>

<!--
[TODO Hans: replace the three headline numbers with your current firsthand figures before the workshop — these are order-of-magnitude from public Nais talks.]

Hans speaks from experience here — this is the "I work on this" slide, and it's the credibility anchor for the whole day: platform engineering isn't a conference fashion, it's how a critical national institution ships software.

Key beats:
- Nav's developers don't file tickets for databases, queues or TLS. They declare dependencies in nais.yaml, and reconciliation loops (the same operator pattern as today's CNPG and Crossplane) make it true.
- The platform team is small relative to the teams it serves — that ratio is the economic argument for platform engineering. One team amortizes ops, security and upgrades across every product team.
- Nais is open source — same spirit as everything on today's stack.
- And the nuance that makes this talk honest: Nais itself runs on rented infrastructure where that's the right trade (GKE, managed Kafka). Sovereignty is a dial, not a switch — Nav chooses per workload. Today you build the far end of that dial, so that the choice is real for you too.
-->

---

# Five things Nav's platform got right

<div class="grid grid-cols-1 gap-2 mt-2">
  <div class="story"><span class="tag">GOLDEN PATH</span> &nbsp;One manifest declares the app <em>and</em> its dependencies → <strong>module 04's <code>Application</code> XR</strong> is you building exactly this</div>
  <div class="story"><span class="tag">SELF-SERVICE</span> &nbsp;No tickets, no humans in the loop — ask in git, reconciliation makes it true → <strong>modules 02–04</strong></div>
  <div class="story"><span class="tag">SECURE DEFAULTS</span> &nbsp;Zero-trust network policy is the <em>default</em>, teams declare exceptions → <strong>the security door, later today</strong></div>
  <div class="story"><span class="tag">BATTERIES INCLUDED</span> &nbsp;Observability comes with the platform, not per-team → <strong>the Victoria + OTel catalog apps</strong></div>
  <div class="story"><span class="tag">PLATFORM AS PRODUCT</span> &nbsp;Teams are customers who could go elsewhere — the platform earns adoption → <strong>the whole design of today</strong></div>
</div>

<!--
This is the map between the real world and the next four hours — each learning points at the module where the room builds its miniature version.

- Golden path: nais.yaml's core idea — the manifest declares dependencies, not just the deployment — is precisely the Application XR of module 04/09. Say it explicitly: "you are building a build-your-own-Nais today."
- Self-service: the 2008 cloud magic, reclaimed. At Nav it's git + operators; today it's git + operators. Identical mechanism, different scale.
- Secure defaults: at Nav, apps can't talk to each other until an access policy says so. Making the secure path the default path is the deepest lesson — and the security adventure lets people feel it by breaking a live pipeline with default-deny and earning it back.
- Batteries included: if every team must assemble its own observability, most won't. Platform-provided telemetry is why module 09's "one trace in Grafana" moment costs the attendee a single catalog file.
- Platform as product: the meta-learning. A platform nobody wants to use is infrastructure with extra steps. Docs, DX, and the paved road being genuinely nicer — that's the job. Today's repo (hints, catch-up.sh, verify.sh) tries to practice what it preaches.

Transition: "So that's the discipline. Here's the specific stack we'll do it with." → stack section.
-->
