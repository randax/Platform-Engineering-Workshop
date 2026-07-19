---
layout: section
---

# What you built today

<!--
Closing section — bring the energy back to the front of the room for the last ten minutes (the 30 minutes of tinkering happen around it).
-->

---

# The box, now full

<div class="arch done">
  <div class="laptop">
    <div class="band-title"><Logo name="docker" size="1.3rem"/> Your laptop · Docker — still yours when the lid closes</div>
    <div class="k8s">
      <div class="band-title"><Logo name="talos" size="1.3rem"/> <Logo name="cilium" size="1.3rem"/> ✅ Talos + Cilium · Kubernetes — running (01)</div>
      <div class="engine">
        <Logo name="gitea" label size="1.7rem"/> <span class="arrow">→</span> <Logo name="argocd" label="Argo CD" size="1.7rem"/>
        <span class="delivers">✅ every box below, delivered by git (02)</span>
      </div>
      <div class="services">
        <Logo name="cloudnativepg" label="CloudNativePG · 03" size="1.6rem"/>
        <Logo name="rustfs" text="RustFS" size="1.6rem"/>
        <Logo name="crossplane" label="Crossplane · 04" size="1.6rem"/>
        <Logo name="knative" label="Knative · 06+09" size="1.6rem"/>
        <Logo name="nats" label="NATS · 09" size="1.6rem"/>
        <Logo name="argo-workflows" label="CI · 07" size="1.6rem"/>
        <Logo name="cloudbox" text="Cloudbox" size="1.6rem"/>
        <Logo name="grafana" label="Victoria + OTel" size="1.6rem"/>
      </div>
    </div>
  </div>
</div>

<!--
The same diagram from the first ten minutes — but now every box on it is running on the laptops in this room. Walk it once more, fast, in the past tense: "you built an immutable OS layer with no kube-proxy; you gave your cluster its own git server and made git the only way anything changes; you became the RDS team and the S3 team; you shipped a self-service API on Crossplane v2; you debugged it like an SRE and fact-checked an AI agent doing the same; and some of you added serverless, in-cluster CI, a portal you can read, and an event-driven pipeline traced end to end."

Then the sovereignty callback: no account was created today. No bill will arrive. Nothing phones home. When the laptop lid closes, the cloud goes to sleep — and it wakes up still yours.

The mental model is the real takeaway: cloud products are software plus an API, and every one of them has an open-source shape you can own.
-->

---

# Remember the table? All yours now.

<div class="allgreen">
<table>
<thead><tr><th>Cloud primitive</th><th>You're running</th></tr></thead>
<tbody>
<tr><td>Kubernetes / compute</td><td><span class="svgi i-check" style="color:var(--jz-run)"></span> <Logo name="talos" label size="1.5rem"/> <Logo name="cilium" label size="1.5rem"/></td></tr>
<tr><td>Managed Postgres</td><td><span class="svgi i-check" style="color:var(--jz-run)"></span> <Logo name="cloudnativepg" label size="1.5rem"/></td></tr>
<tr><td>Object storage (S3)</td><td><span class="svgi i-check" style="color:var(--jz-run)"></span> <Logo name="rustfs" text="RustFS" size="1.5rem"/></td></tr>
<tr><td>Self-service infra</td><td><span class="svgi i-check" style="color:var(--jz-run)"></span> <Logo name="crossplane" label size="1.5rem"/></td></tr>
<tr><td>Serverless · CI · registry</td><td><span class="svgi i-check" style="color:var(--jz-run)"></span> <Logo name="knative" label size="1.5rem"/> <Logo name="argo-workflows" label="Argo Workflows" size="1.5rem"/> <Logo name="zot" text="Zot" size="1.5rem"/></td></tr>
<tr><td>Cloud console</td><td><span class="svgi i-check" style="color:var(--jz-run)"></span> <Logo name="cloudbox" text="Cloudbox" size="1.5rem"/></td></tr>
</tbody>
</table>
</div>

<div class="mt-6 text-xl opacity-80">No account. No bill. No permission.</div>

<!--
The bookend: this is the exact comparison table from the opening "What is a cloud" section — the left column was what you'd rent from a hyperscaler. Now the right column is running on the laptop in front of you, every row green.

Say it plainly: "Four hours ago this was a shopping list of things you pay for. Now it's a list of things you own." Then bring it home to Bruktby on the next slide.
-->

---

# So what did Bruktby actually get?

<div class="ba">
  <div class="before">
    <h3>v1 — rented</h3>
    The same product, on a US hyperscaler. Three bills they didn't control:
    <br>• storage + egress on every listing photo
    <br>• user data under someone else's law
    <br>• a core service relicensed out from under them
  </div>
  <div class="after">
    <h3>today — owned</h3>
    Photos in, listings out — on a platform <em>they run</em>:
    <br>• data stays in Norway, provably
    <br>• no per-photo egress bill; scales to zero when quiet
    <br>• every component open-source and pinned — nobody can discontinue them
  </div>
</div>

<div class="mt-5 text-lg opacity-85">
Same product. Same photo pipeline. A cloud they own — and the migration was ~9 open-source components and a laptop.
</div>

<!--
This is the payoff slide the whole story has been building to — say what the outcome actually IS, in Bruktby's terms, because "you built a cloud" is abstract until it's someone's real product.

Walk the two columns as a before/after: v1 wasn't wrong — it got them to market — but the three forces from the opening (price, jurisdiction, roadmap) each took a decision out of their hands. Today the identical product runs on infrastructure they control: the listings Postgres is CloudNativePG, the photos live in RustFS buckets on disks they own, the thumbnailer is a Knative service that costs nothing between uploads, and the whole thing was delivered by git and is traceable end to end. Data residency is now a fact they can prove to that B2B partner, not a region setting they hope is good enough.

The sentence to land: "The complete outcome of today isn't 'you learned Kubernetes.' It's that a real product can run — same features, same UX — on a cloud its team owns, and you just did the migration end to end." Then the sovereignty line one more time, and hand to take-home.
-->

---

# Take it home

- Everything is public, pinned, Apache-2.0
- `catch-up.sh <module>` — resume from anywhere
- Skipped the stretch? It's all still there
- `git tag javazone-2026` = today, forever
- Broken prereqs at home? Open an issue

<!--
The platform survives the room — that was the design goal, so make the path home concrete:

- The repo (github.com/randax/Platform-Engineering-Workshop) contains labs, hints, solutions, scripts, and these slides. Apache 2.0: take it, fork it, run your cloud on your terms.
- catch-up.sh <module> works on a fresh cluster at home exactly like it did here — you can rebuild to any module's end-state in minutes and continue from there. The solutions/ directory holds every canonical end-state.
- The stretch modules were designed for the couch as much as for the room: Knative, in-cluster CI, the portal source, the capstone. Nothing needs conference infrastructure.
- The javazone-2026 tag freezes today's exact versions — in a year, when everything has drifted, the tag still builds.
- And genuinely: broken prereqs or labs are OUR bug — issues welcome.
-->

---

# Going deeper

- Talos · Cilium — the metal layer
- ArgoCD · Gitea — the delivery layer
- CloudNativePG · RustFS — the data layer
- Crossplane v2 · Knative · Zot — the platform layer
- All linked from the repo README

<!--
Further-reading pointers, one line each — the repo README links all of them so nobody needs to photograph this slide:

- talos.dev and cilium.io — go deeper on the OS and eBPF layers; Talos on real hardware (or a stack of NUCs) is the natural next step after Talos-in-Docker.
- argo-cd.readthedocs.io and gitea — the app-of-apps and sync-wave patterns used today are documented ArgoCD idioms, not workshop inventions.
- cloudnative-pg.io — backups, PITR, and replicas are where the operator really starts earning its keep; rustfs.com for where RustFS goes post-1.0 (and SeaweedFS as the alternative we'd reach for).
- crossplane.io (make sure it says v2!), knative.dev, zotregistry.dev, backstage.io for the honest big-portal path, and the VictoriaMetrics stack (victoriametrics.com — VictoriaMetrics/VictoriaLogs/VictoriaTraces) fronted by Grafana and fed by the OpenTelemetry Collector for the on-demand observability layer.

Also plug the ecosystem around this audience: CNCF meetups, GDG Bergen, and Plattformpodden (Norwegian-language platform-engineering podcast Hans co-hosts) for continuing the conversation.
-->

---
layout: cover
---

# Thank you

**Your laptop. Your cloud. Your terms.**

<div class="pt-8 text-sm leading-relaxed opacity-85">
  <strong>Øyvind Randa</strong> — Software Architect, NextGenTel · GDG Bergen<br>
  <strong>Hans Kristian Flaatten</strong> — Platform Engineer, Norwegian Government · CNCF Ambassador · Plattformpodden
</div>

<div class="callout mt-8 mx-auto max-w-120">
  <code>github.com/randax/Platform-Engineering-Workshop</code><br>
  <span class="svgi i-star"></span> it — then go run your cloud on your terms.
</div>

<!--
Final slide — leave it up during the protected tinkering time and the goodbyes.

Thank the helpers by name; they carried the room. Thank JavaZone.

Invitations to end on:
- "The cluster on your laptop is not a demo — it's yours. Keep it. Break it. Rebuild it with catch-up."
- Find us afterwards — here, in the hallway, at the CNCF/GDG meetups, or via the repo. Both of us genuinely want to hear what you build (or what broke) when you run this at home.
- Feedback: issues and PRs on the repo are the best thank-you there is.

(If JavaZone provides a feedback QR/link for the session, put it on the projector next to this slide.)
-->
