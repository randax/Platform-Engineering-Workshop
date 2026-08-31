---
layout: section
transition: view-transition
---

<span class="badge">Module 00 · gate · runs during the intro</span>

# Setup & pre-flight

<div class="modlogos"><Logo name="docker" label size="2.6rem"/> <Logo name="kubernetes" label size="2.6rem"/></div>

<!--
This is the safety net, not the plan. The prework email asked everyone to do this at home. Module 00 therefore gets no slot of its own: the check itself takes nine seconds, and what needs time is FIXING what it flags, which wants 1:1 triage on the floor, not the room's attention.

So release the room to run it here, at minute 10, and keep talking. The concept sections that follow (what · platforms · stack · how) are deliberately zero-keyboard, so the pre-flight, the image pull and the presenter all run in parallel. Triage happens just before module 01.

Anyone whose laptop fundamentally can't run it goes straight to a lifeboat (pair up, or devcontainer/Codespaces). Do NOT let anyone burn 45 minutes fighting their runtime install, on either substrate.
-->

---
transition: view-transition
---

# WiFi carries keystrokes, not gigabytes

- Every image pre-pulled, every version pinned
- Nothing downloads at runtime, by design
- That **is** platform lesson #1:
- A platform needing internet is someone else's

<!--
The offline rule isn't just conference pragmatism. It's the first platform-engineering lesson of the day. If your platform can't stand up without reaching the internet, it isn't your platform; it's a client of someone else's.

Concretely: cloudbox-init.sh pre-pulled all pinned images into a local registry mirror; the git server will live in-cluster; ArgoCD never points at GitHub. Once images are pulled, the whole workshop works in airplane mode.

Hardware honesty, one more time: 16 GB RAM is the minimum on both substrates, 32 GB is comfortable, and you need ~40 GB free disk; the image caches are most of it. The full platform idles around 8 GB inside the cluster, so on 16 GB machines: close the Electron zoo. On the Docker substrate you also need ≥10 GB and ≥4 CPUs allocatable to Docker (macOS: OrbStack or Docker Desktop with a raised limit; WSL2: .wslconfig). WSL2 is Docker-only and our least-tested platform, so lifeboats apply there first.

THIS IS ALSO THE MODULE 00 RELEASE POINT. There is no separate GO slide: the terminal slide near the front already showed the whole sequence, ending on `cd lab/00-setup && ./verify.sh`. Release the room here and keep talking. The next four sections are deliberately zero-keyboard, so the pre-flight, the image pull and the presenter run in parallel. Red sticky if anything is ❌.

Substrate, said once so nobody is confused by their neighbour's terminal: the scripts pick real Talos VMs (talos-box) where `tbx doctor` passes (Apple Silicon and Linux with KVM) and Talos-in-Docker everywhere else. `cat ~/.cloudbox/substrate` says which one a machine got, `CLOUDBOX_SUBSTRATE=docker` forces the fallback, and every module after 01 is identical on both. Anyone who skipped the prework's optional tbx step is not stuck; they get the Docker path.

The prework line that pays off later: the optional OpenCode Zen key from lab/00-setup's README is what door 0's module 10 needs for its second beat. Anyone who skipped it should grab it now, while there is WiFi to spare.

Already green because you did the prework? You have a free half hour: skim lab/01-cluster/README.md, or help a neighbour, which is the fastest way to learn this material.

Triage: image pulls not done is the only unfixable-in-room problem (bandwidth): those people pair up or go to Codespaces immediately. Everything else (memory limits, missing tools) is a 2-minute fix. At the checkpoint just before module 01, ~90% green is enough to start; stragglers keep pulling in the background and module 01 does not need the images immediately.
-->
