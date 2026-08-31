---
theme: seriph
title: Cloud on Your Terms — Building Your Own Cloud-Native Platform
titleTemplate: '%s'
info: |
  ## JavaZone 2026 — Platform Engineering Workshop

  Build a complete cloud-native platform — Kubernetes, GitOps, databases-as-a-service,
  object storage, self-service infrastructure — running entirely on your own laptop.

  Speakers: Øyvind Randa & Hans Kristian Flaatten
class: text-center
highlighter: shiki
drawings:
  persist: false
transition: slide-left
mdc: true
# Slidev disables text selection so drag gestures advance/draw. This deck is a
# reference attendees copy commands out of, so selection is worth more here.
selectable: true
fonts:
  provider: none
# offline rule: no CDN assets — inline emoji favicon instead of Slidev's jsdelivr default
favicon: 'data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>☁️</text></svg>'
themeConfig:
  primary: '#38bdf8'
layout: cover
---

# Cloud on Your Terms

## Building Your Own Cloud-Native Platform

<div class="pt-2 text-lg opacity-90">JavaZone 2026</div>

<div class="coverlogos">
  <div class="coverlogos-track">
    <div class="coverlogos-set"><Logo name="talos" size="1.4rem"/><Logo name="cilium" size="1.4rem"/><Logo name="gitea" size="1.4rem"/><Logo name="argocd" size="1.4rem"/><Logo name="cloudnativepg" size="1.4rem"/><Logo name="rustfs" size="1.4rem"/><Logo name="crossplane" size="1.4rem"/><Logo name="knative" size="1.4rem"/><Logo name="nats" size="1.4rem"/><Logo name="grafana" size="1.4rem"/><Logo name="opentelemetry" size="1.4rem"/></div>
    <div class="coverlogos-set" aria-hidden="true"><Logo name="talos" size="1.4rem"/><Logo name="cilium" size="1.4rem"/><Logo name="gitea" size="1.4rem"/><Logo name="argocd" size="1.4rem"/><Logo name="cloudnativepg" size="1.4rem"/><Logo name="rustfs" size="1.4rem"/><Logo name="crossplane" size="1.4rem"/><Logo name="knative" size="1.4rem"/><Logo name="nats" size="1.4rem"/><Logo name="grafana" size="1.4rem"/><Logo name="opentelemetry" size="1.4rem"/></div>
    <div class="coverlogos-set" aria-hidden="true"><Logo name="talos" size="1.4rem"/><Logo name="cilium" size="1.4rem"/><Logo name="gitea" size="1.4rem"/><Logo name="argocd" size="1.4rem"/><Logo name="cloudnativepg" size="1.4rem"/><Logo name="rustfs" size="1.4rem"/><Logo name="crossplane" size="1.4rem"/><Logo name="knative" size="1.4rem"/><Logo name="nats" size="1.4rem"/><Logo name="grafana" size="1.4rem"/><Logo name="opentelemetry" size="1.4rem"/></div>
    <div class="coverlogos-set" aria-hidden="true"><Logo name="talos" size="1.4rem"/><Logo name="cilium" size="1.4rem"/><Logo name="gitea" size="1.4rem"/><Logo name="argocd" size="1.4rem"/><Logo name="cloudnativepg" size="1.4rem"/><Logo name="rustfs" size="1.4rem"/><Logo name="crossplane" size="1.4rem"/><Logo name="knative" size="1.4rem"/><Logo name="nats" size="1.4rem"/><Logo name="grafana" size="1.4rem"/><Logo name="opentelemetry" size="1.4rem"/></div>
    <div class="coverlogos-set" aria-hidden="true"><Logo name="talos" size="1.4rem"/><Logo name="cilium" size="1.4rem"/><Logo name="gitea" size="1.4rem"/><Logo name="argocd" size="1.4rem"/><Logo name="cloudnativepg" size="1.4rem"/><Logo name="rustfs" size="1.4rem"/><Logo name="crossplane" size="1.4rem"/><Logo name="knative" size="1.4rem"/><Logo name="nats" size="1.4rem"/><Logo name="grafana" size="1.4rem"/><Logo name="opentelemetry" size="1.4rem"/></div>
    <div class="coverlogos-set" aria-hidden="true"><Logo name="talos" size="1.4rem"/><Logo name="cilium" size="1.4rem"/><Logo name="gitea" size="1.4rem"/><Logo name="argocd" size="1.4rem"/><Logo name="cloudnativepg" size="1.4rem"/><Logo name="rustfs" size="1.4rem"/><Logo name="crossplane" size="1.4rem"/><Logo name="knative" size="1.4rem"/><Logo name="nats" size="1.4rem"/><Logo name="grafana" size="1.4rem"/><Logo name="opentelemetry" size="1.4rem"/></div>
  </div>
</div>

<div class="speakers">
  <div class="speaker">
    <img src="/speakers/oyvind.jpg" alt="Øyvind Randa" />
    <div><strong>Øyvind Randa</strong><br>Software Architect at NextGenTel, Lead Organizer GDG Bergen</div>
  </div>
  <div class="speaker">
    <img src="/speakers/hans.jpg" alt="Hans Kristian Flaatten" />
    <div><strong>Hans Kristian Flaatten</strong><br>Platform Engineer in Norwegian Government, CNCF Ambassador</div>
  </div>
</div>

<div class="callout mt-5 mx-auto max-w-130">
  <strong>Did you run the prework?</strong><br>
  <code>mise run preflight</code> must be all green.<br>
  Not green? Start <strong>now</strong> — or grab one of us.
</div>

<div class="abs-br m-6 text-sm opacity-60">
  github.com/randax/Platform-Engineering-Workshop
</div>

<!--
Welcome! While people trickle in, this slide does the most important job of the day: getting everyone to run the pre-flight check immediately.

- Introduce yourselves briefly: Øyvind (NextGenTel, GDG Bergen) and Hans (platform engineer in the Norwegian Government, CNCF Ambassador, co-host of Plattformpodden).
- Point at the callout: "If you haven't run the three prework scripts, start `mise run init` RIGHT NOW — it pre-pulls several gigabytes of images and it's the only step that needs real bandwidth. Everything else today works offline."
- Repo URL is at the bottom — it's public, everything (labs, solutions, slides) lives there, and it will keep working after today.
- Staffing: it's the two of you and nobody else — say so, and explain the sticky notes briefly (more in a few slides).

Timing: ~10 minutes for the cover + "why", then module 00's GO slide puts hands on keyboards at minute 10. The pre-flight runs in the background while the concept sections play; we triage it just before module 01.
-->

---
layout: full
class: term-slide
---

<div class="term">
  <div class="term-bar"><span class="d r"></span><span class="d y"></span><span class="d g"></span>
    <span class="term-title">~/Platform-Engineering-Workshop</span></div>
  <div class="term-body">

<div style="--d:0.2s"><span class="p">$</span> <span class="c">git clone https://github.com/randax/Platform-Engineering-Workshop.git</span></div>
<div style="--d:1.2s"><span class="p">$</span> <span class="c">cd Platform-Engineering-Workshop</span></div>

<div class="gap" style="--d:1.9s"><span class="p">$</span> <span class="c">./scripts/dev-setup.sh</span></div>
<div class="o ok" style="--d:3.2s">✅ pinned tool chain installed</div>

<div class="gap" style="--d:3.9s"><span class="p">$</span> <span class="c">mise run init</span></div>
<div class="o ok" style="--d:5.4s">✅ 76 images warmed, 0 failed</div>

<div class="gap" style="--d:6.1s"><span class="p">$</span> <span class="c">mise run preflight</span></div>
<div class="o ok" style="--d:7.2s">✅ all checks passed</div>

<div class="gap" style="--d:7.9s"><span class="p">$</span> <span class="c">cd lab/00-setup &amp;&amp; ./verify.sh</span></div>
<div class="o ok" style="--d:8.9s">✅ module 00 complete<span class="cur"></span></div>

  </div>
</div>

<!--
Leave this up while people trickle in, and come back to it at every "I'm stuck before we even start".

It plays itself, about ten seconds end to end, and it never advances the slide. Let it run behind you while you talk; press right when YOU are ready, not when the animation is.

Why `mise run` for steps 2 and 3 but a bare script for step 1: dev-setup.sh is what installs mise and trusts mise.toml, so it cannot be a mise task on a machine that has no mise yet. After it, `mise run init` and `mise run preflight` are the same scripts with the pinned tool chain guaranteed on PATH. `mise tasks` lists the rest.

The one thing worth saying aloud: pick one side and stay on it. Running scripts through mise while typing bare kubectl in a shell that never got the pin means your cluster and your terminal are looking at two different kubeconfigs. install.sh --check tells you which side you are on.

Do not wait for the room. Steps 1 and 2 were the prework email; anyone who did it is already green. Step 2 is the one that fails at a conference, so pair anyone starting it now with a neighbour who is done rather than letting them race 7.5 GB over venue WiFi.
-->

---
src: ./pages/why.md
---

---
transition: view-transition
---

# What you'll walk out able to do

<div class="grid grid-cols-2 gap-3 mt-4">
  <div class="principle"><div class="ico"><span class="svgi i-hexagon"></span></div><div class="name">Run Kubernetes you own</div><div class="tie">a declarative node with no shell to drift into</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-workflow"></span></div><div class="name">Ship everything through git</div><div class="tie">on a git server that lives in your own cluster</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-package"></span></div><div class="name">Offer databases and storage as a service</div><div class="tie">to your developers, from your own hardware</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-concierge-bell"></span></div><div class="name">Replace the ticket with an API</div><div class="tie">one YAML, no platform team in the loop</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-brain"></span></div><div class="name">Debug a platform you built</div><div class="tie">and check what an AI claims about it</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-star"></span></div><div class="name">Take the whole thing home</div><div class="tie">pinned, offline, still yours next year</div></div>
</div>

<!--
Say this as the contract for the day, and keep it short — it is a promise slide, not a lecture. These are capabilities, deliberately not a tool list: nobody remembers "Crossplane v2" a month later, but "I replaced a ticket queue with an API" sticks.

The one to land hardest is the last. Everything here keeps working after you close the lid: no trial, no account, no bill. That is the whole argument of the workshop compressed into one line.

If the room is running late, this slide can be read in twenty seconds — it is scaffolding for what follows, and every item gets built for real later.
-->

---

# Five tips, then we start

<div class="grid grid-cols-2 gap-3 mt-4">
  <div class="principle"><div class="ico"><span class="svgi i-target"></span></div><div class="name">Try before you open a hint</div><div class="tie">the labs give outcomes on purpose; a wrong guess teaches more than a right paste</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-fast-forward"></span></div><div class="name">Falling behind is designed for</div><div class="tie"><code>mise run catch-up &lt;n&gt;</code> is not failure, it is the safety net</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-book-open"></span></div><div class="name">Explain it to your neighbour</div><div class="tie">a fix you cannot explain is not finished</div></div>
  <div class="principle"><div class="ico"><span class="svgi i-puzzle"></span></div><div class="name">Ask "why this, not that?"</div><div class="tie">every pick here beat a rejected alternative — make us defend them</div></div>
  <div class="principle col-span-2"><div class="ico"><span class="svgi i-sparkles"></span></div><div class="name">Don't just hand it to your AI companion</div><div class="tie">agents are welcome all day, as a <strong>tutor, not a chauffeur</strong> — a lab your agent solved is a lab you didn't learn, and you can't take that home</div></div>
</div>

<div class="mt-5 text-center text-lg opacity-85">Depth beats speed. Finishing every module is <strong>not</strong> the goal.</div>

<!--
Five tips, thirty seconds, then move. Do not turn this into a lecture on how to learn.

"Try before you open a hint" is the one that changes behaviour: the hints are free and uncounted, and the last one is always the full answer, so nobody is being tested. The ask is only that they spend a minute thinking first — that minute is where the learning actually happens.

Say the catch-up line without shame in your voice, because the room takes its cue from you: "catch-up is not failure, it is how this workshop absorbs variance." An attendee who believes that will experiment; one who does not will sit frozen at a broken cluster rather than skip ahead.

The explain-back is the cheapest quality gate in the day. Two minutes at each module boundary, tell the person next to you WHY it works. It also solves the pairing problem for anyone who came alone.

"Why this, not that?" is an invitation, and you should mean it: the stack slides carry a Rejected column for exactly this reason. Being asked to defend Talos over kubeadm in front of the room is a good outcome, not an interruption.

The AI tip is the one to say in your own words, because the room will assume you mean the opposite. We are not banning agents — a later slide says they are explicitly welcome and the repo itself tells them to coach rather than solve. The point is narrower and worth being blunt about: if you paste the lab into an agent and paste its answer back, you will finish the module and leave with nothing. The cluster goes home with you; the understanding only does if you built it.

Frame it as self-interest rather than a rule. Nobody is checking, there is no penalty, and the last hint is the full answer anyway. The person who lets an agent drive is not cheating the workshop, they are cheating themselves out of the one thing a video or a chatbot could not have given them.

The closing line matters most for the fast people: several modules have a Going deeper section, and going deeper on module 04 is worth more than rushing to module 09. Nobody is scored on how far they get.
-->

---
src: ./pages/module-00.md
---

---
src: ./pages/what.md
---

---
src: ./pages/platforms.md
---

---
src: ./pages/stack.md
---

---
src: ./pages/how.md
---

---
src: ./pages/module-01.md
---

---
src: ./pages/module-02.md
---

---
src: ./pages/module-03.md
---

---
src: ./pages/module-04.md
---

---
src: ./pages/module-05.md
---

---
src: ./pages/module-06.md
---

---
src: ./pages/module-09.md
---

---
src: ./pages/adventures.md
---

---
src: ./pages/module-07.md
---

---
src: ./pages/module-08.md
---

---
src: ./pages/module-10.md
---

---
src: ./pages/principles.md
---

---
src: ./pages/closing.md
---
