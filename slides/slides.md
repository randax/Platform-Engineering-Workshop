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
  <code>./scripts/install.sh --check</code> must be all green.<br>
  Not green? Start <strong>now</strong> — or grab one of us.
</div>

<div class="abs-br m-6 text-sm opacity-60">
  github.com/randax/Platform-Engineering-Workshop
</div>

<!--
Welcome! While people trickle in, this slide does the most important job of the day: getting everyone to run the pre-flight check immediately.

- Introduce yourselves briefly: Øyvind (NextGenTel, GDG Bergen) and Hans (platform engineer in the Norwegian Government, CNCF Ambassador, co-host of Plattformpodden).
- Point at the callout: "If you haven't run the three prework scripts, start `./scripts/cloudbox-init.sh` RIGHT NOW — it pre-pulls several gigabytes of images and it's the only step that needs real bandwidth. Everything else today works offline."
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
    <span class="term-title">~ — the only three commands you need today</span></div>
  <div class="term-body">

<div style="--d:0.2s"><span class="p">$</span> <span class="c">git clone https://github.com/randax/Platform-Engineering-Workshop.git</span></div>
<div class="o" style="--d:1.3s">Cloning into 'Platform-Engineering-Workshop'... done.</div>
<div style="--d:1.7s"><span class="p">$</span> <span class="c">cd Platform-Engineering-Workshop</span></div>

<div class="gap" style="--d:2.3s"><span class="p">$</span> <span class="c">./scripts/dev-setup.sh</span></div>
<div class="o" style="--d:2.6s">installing the pinned tool chain with mise…</div>
<div class="o ok" style="--d:4.2s">✅ talosctl, kubectl, helm, crane — pinned &nbsp;✅ mise.toml trusted</div>

<div class="gap" style="--d:4.9s"><span class="p">$</span> <span class="c">mise run init</span> <span class="cm"># pre-pull ~7.5 GB · the only step that needs bandwidth</span></div>
<div class="o ok" style="--d:6.6s">✅ 76 images warmed into the mirror, 0 failed</div>

<div class="gap" style="--d:7.2s"><span class="p">$</span> <span class="c">mise run preflight</span> <span class="cm"># Docker, resources, tools, images</span></div>
<div class="o ok" style="--d:8.1s">✅ Host memory: 32 GB &nbsp;✅ Host CPUs: 10 &nbsp;✅ Free disk: 96 GB</div>
<div class="o ok" style="--d:8.4s">✅ Docker daemon reachable &nbsp;✅ images complete &nbsp;✅ kubeconfig writable</div>
<div class="o done" style="--d:9.0s">✅ All checks passed — you are ready for the workshop! 🎉</div>

<div class="gap" style="--d:9.8s"><span class="p">$</span> <span class="c">cd lab/00-setup &amp;&amp; ./verify.sh</span> <span class="cm"># module 00, and you are done</span></div>
<div class="o done" style="--d:10.6s">✅ Module 00 complete<span class="cur"></span></div>

<div class="term-foot" style="--d:11.4s">Red anywhere? The output names the fix. Still stuck: <strong>grab one of us</strong>, or take the Codespaces lifeboat.</div>

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
