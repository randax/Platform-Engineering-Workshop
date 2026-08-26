---
layout: section
transition: view-transition
---

<span class="badge">Module 00 · gate · runs during the intro</span>

# Setup & pre-flight

<div class="modlogos"><Logo name="docker" label size="2.6rem"/> <Logo name="kubernetes" label size="2.6rem"/></div>

<!--
This is the safety net, not the plan — the prework email asked everyone to do this at home. Module 00 therefore gets no slot of its own: the check itself takes nine seconds, and what needs time is FIXING what it flags — which wants a helper, not the room's attention.

So release the room to run it here, at minute 10, and keep talking. The concept sections that follow (what · platforms · stack · how) are deliberately zero-keyboard, so the pre-flight, the image pull and the presenter all run in parallel. Triage happens just before module 01.

Anyone whose laptop fundamentally can't run it goes straight to a lifeboat (pair up, or devcontainer/Codespaces) — do NOT let anyone burn 45 minutes fighting their Docker install.
-->

---

# WiFi carries keystrokes, not gigabytes

- Every image pre-pulled, every version pinned
- Nothing downloads at runtime — by design
- That **is** platform lesson #1:
- A platform needing internet is someone else's

<!--
The offline rule isn't just conference pragmatism — it's the first platform-engineering lesson of the day. If your platform can't stand up without reaching the internet, it isn't your platform; it's a client of someone else's.

Concretely: cloudbox-init.sh pre-pulled all pinned images into a local registry mirror; the git server will live in-cluster; ArgoCD never points at GitHub. Once images are pulled, the whole workshop works in airplane mode.

Hardware honesty, one more time: 16 GB RAM minimum with at least 10 GB allocatable to Docker; 32 GB is comfortable. The full platform idles around 8 GB inside the cluster. On 16 GB machines: close the Electron zoo. macOS: OrbStack or Docker Desktop with a raised memory limit. WSL2: raise it in .wslconfig — and WSL2 is our least-tested platform, so lifeboats apply.
-->

---

# GO — Module 00

**Outcome:** your laptop is provably ready.

```bash
./scripts/install.sh --check     # all green?
cd lab/00-setup && ./verify.sh
```

<span class="badge">runs in the background</span> · red sticky if anything is <span class="svgi i-circle-x"></span>

<!--
The task: run the pre-flight, fix what it flags (most common: Docker not running, or Docker memory limit below 10 GB), and run the module's verify.sh. No timer on this one — it runs underneath the next four sections.

Say the one prework line that pays off later: the optional OpenCode Zen key from lab/00-setup's README is what door 0's module 10 needs for its second beat. Anyone who skipped it should grab it now, while there's WiFi to spare.

Already green because you did the prework? Perfect — you have a free half hour: skim lab/01-cluster/README.md, or help a neighbor. Helping a neighbor is the fastest way to learn this material.

Triage guidance for presenters/helpers: image pulls not done is the only unfixable-in-room problem (bandwidth) — those people pair up or go to Codespaces immediately. Everything else (memory limits, missing tools) is a 2-minute fix.

At the triage checkpoint just before module 01, ~90% green is enough to start — stragglers keep pulling in the background and module 01 doesn't need the images immediately.
-->
