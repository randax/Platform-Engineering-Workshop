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

<div class="pt-4 text-lg opacity-90">JavaZone 2026 · 4-hour hands-on workshop</div>

<div class="pt-6 text-sm leading-relaxed opacity-80">
  <strong>Øyvind Randa</strong> — Software Architect at NextGenTel, Lead Organizer GDG Bergen<br>
  <strong>Hans Kristian Flaatten</strong> — Platform Engineer in Norwegian Government, CNCF Ambassador
</div>

<div class="callout mt-8 mx-auto max-w-130">
  <strong>Did you run the prework?</strong><br>
  <code>./scripts/install.sh --check</code> must be all green.<br>
  Not green? Start <strong>now</strong> — or grab a helper.
</div>

<div class="abs-br m-6 text-sm opacity-60">
  github.com/randax/Platform-Engineering-Workshop
</div>

<!--
Welcome! While people trickle in, this slide does the most important job of the day: getting everyone to run the pre-flight check immediately.

- Introduce yourselves briefly: Øyvind (NextGenTel, GDG Bergen) and Hans (platform engineer in the Norwegian Government, CNCF Ambassador, co-host of Plattformpodden).
- Point at the callout: "If you haven't run the three prework scripts, start `./scripts/cloudbox-init.sh` RIGHT NOW — it pre-pulls several gigabytes of images and it's the only step that needs real bandwidth. Everything else today works offline."
- Repo URL is at the bottom — it's public, everything (labs, solutions, slides) lives there, and it will keep working after today.
- Helpers: point them out, explain the sticky notes briefly (more on that in a few slides).

Timing: keep the cover + "why" section to ~15 minutes total. Hands on keyboards within the first 10 minutes is the goal — module 00 is running in the background for anyone who skipped the prework.
-->

---
src: ./pages/why.md
---

---
src: ./pages/what.md
---

---
src: ./pages/stack.md
---

---
src: ./pages/how.md
---

---
src: ./pages/module-00.md
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
src: ./pages/module-07.md
---

---
src: ./pages/module-08.md
---

---
src: ./pages/module-09.md
---

---
src: ./pages/closing.md
---
