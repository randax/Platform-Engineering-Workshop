---
layout: section
---

# So what *is* a cloud, anyway?

<!--
This section runs while the last laptops are still pulling images — it needs zero keyboard, just attention. Its job: turn "the cloud" from a place you rent into a list of things you can build. Every module later is one row of the table you're about to show. ~8 minutes, unhurried.

If cloudbox-init is still downloading for some people, say so now: "This next bit is exactly why we front-loaded the download — watch the screen, your laptop keeps working in the background."
-->

---
layout: fact
---

<div class="flex justify-center mb-2">
<svg width="210" height="150" viewBox="0 0 640 512" fill="none" xmlns="http://www.w3.org/2000/svg">
  <path d="M537 179c44 0 79 36 79 80s-35 80-79 80H152c-66 0-120-54-120-120s54-120 120-120c8 0 16 1 23 3 21-47 68-80 122-80 74 0 134 60 134 134 0 5 0 10-1 15 8-4 17-6 27-6z" stroke="#7dd3fc" stroke-width="15"/>
  <line x1="96" y1="452" x2="548" y2="70" stroke="#fb7185" stroke-width="22" stroke-linecap="round"/>
</svg>
</div>

# There is no cloud.

It's just **someone else's computer.**

<div class="mt-8 text-2xl opacity-80">Today we make it <strong>yours.</strong></div>

<!--
The sticker everyone's seen — say it with the shrug it deserves, then take the other half seriously.

The joke is true, and that's the good news. "The cloud" is not exotic hardware; it's ordinary computers plus software that turns them into rentable primitives. The hyperscaler's moat was never the metal — you have metal, it's under your fingers right now. The moat is the software on top: the APIs, the automation, the self-service. And that software — all of it — is open source.

So the meme is our thesis, inverted: if a cloud is just someone else's computer, then your computer, plus the right open-source control plane, is a cloud. That's the whole workshop in one line.
-->

---

# What makes a computer a *cloud*

Three things — none of them the hardware:

- **Primitives** — compute, storage, databases, delivered as APIs
- **A control plane** — software that provisions and heals them
- **Self-service** — you *ask*, and it appears; nobody files a ticket

<div class="mt-8 text-xl opacity-80">
The magic was always the control plane, never the metal.
</div>

<!--
Walk the three, slowly — this is the mental model the whole day hangs on:

1. Primitives: a cloud sells you building blocks — a database, a bucket, a function — each behind an API, not a rack you wire up. You compose primitives; you don't assemble servers.
2. Control plane: behind every "managed" service is a control loop that provisions, monitors, fails over, backs up. That software is the product. When you pay for RDS, you're paying for that loop, not for Postgres.
3. Self-service: the thing that made cloud feel like magic in 2008 wasn't virtualization — it was that a developer could *ask* for a database and get one in minutes, with no human in the loop.

Now the punchline that sets up the table: Kubernetes is a control plane. Operators are the control loops. Git is the self-service front door. Every ingredient is open source — so a cloud is a thing you can just... run. Here's the shopping list.
-->

---

# The core primitives are all open source

<div class="compare">
<table>
<thead><tr><th>Cloud primitive</th><th>What you'd rent</th><th>What you'll run today</th></tr></thead>
<tbody>
<tr><td>Kubernetes / compute</td><td><Logo name="aws" dim/> <Logo name="azure" dim/> <Logo name="gcp" dim/></td><td><Logo name="talos" label/> <Logo name="cilium" label/></td></tr>
<tr><td>GitOps delivery</td><td><em>the mechanic itself</em></td><td><Logo name="gitea" label/> <Logo name="argocd" label/></td></tr>
<tr><td>Managed Postgres</td><td>RDS · Cloud SQL · Azure DB</td><td><Logo name="cloudnativepg" label/></td></tr>
<tr><td>Object storage (S3)</td><td>S3 · GCS · Blob</td><td><Logo name="rustfs" text="RustFS"/></td></tr>
<tr><td>Self-service infra</td><td>Service Catalog · CloudFormation</td><td><Logo name="crossplane" label/></td></tr>
<tr><td>Observability</td><td>CloudWatch · Cloud Ops</td><td><Logo name="grafana" label/> <Logo name="opentelemetry" label/></td></tr>
</tbody>
</table>
</div>

<div class="story mt-3"><span class="tag">BRUKTBY</span> &nbsp;The left column is everything Bruktby rented. The right column is what you'll run for them today — same primitive, minus the bill and the account.</div>

<div class="mt-3 text-sm opacity-70">Modules 01–05 — the core. One row each.</div>

<!--
Don't read the table aloud row by row — let them scan it, then make three points:

- The left column is what a hyperscaler charges for. The right column is what runs on your laptop by lunch. Same primitive, both times — the operator on the right IS the managed service on the left, minus the bill and the account.
- GitOps has no clean hyperscaler product to name because it isn't a product — it's the delivery *mechanic*. Everything below ArgoCD arrives as a git commit. That's the one move you'll repeat in every module.
- Nothing here is a toy pick: Cilium, CloudNativePG, Crossplane, OpenTelemetry are all CNCF projects running in real production somewhere right now.

Point at the module map on the wall/handout: "Modules 01 through 05 are literally these six rows, top to bottom."
-->

---

# ...and so is everything above it

<div class="compare">
<table>
<thead><tr><th>Cloud primitive</th><th>What you'd rent</th><th>What you'll run today</th></tr></thead>
<tbody>
<tr><td>Serverless</td><td>Lambda · Cloud Run · Functions</td><td><Logo name="knative" label/></td></tr>
<tr><td>Messaging / queues</td><td>SQS · SNS · Pub/Sub · EventBridge</td><td><Logo name="nats" label="NATS JetStream"/></td></tr>
<tr><td>CI / image builds</td><td>CodeBuild · Cloud Build</td><td><Logo name="argo-workflows" label="Argo Workflows"/> <Logo name="buildkit" label/></td></tr>
<tr><td>Container registry</td><td>ECR · Artifact Registry · ACR</td><td><Logo name="zot" text="Zot"/></td></tr>
<tr><td>Cloud console</td><td><Logo name="aws" dim/> <Logo name="azure" dim/> <Logo name="gcp" dim/></td><td><Logo name="cloudbox" text="Cloudbox"/></td></tr>
</tbody>
</table>
</div>

<div class="mt-4 text-sm opacity-70">The stretch tier — same idea, all the way up the stack.</div>

<!--
The stretch tier, framed as "the cloud doesn't stop at databases":

- Serverless: scale-to-zero request-driven containers. Knative is the open engine underneath a lot of what you'd recognize — it's literally what Google Cloud Run is built on.
- Messaging: durable queues and streams — what makes async reliable. NATS JetStream is the lightweight open answer (≈ SQS/SNS/EventBridge/Pub-Sub): it's the durable counterpart to module 09's in-memory broker, and the queue the golden-path Application XR requests with `spec.queue`.
- CI + registry: the build-and-ship half of a cloud. You'll build a container INSIDE your cluster with Argo Workflows + BuildKit and push it to your own Zot registry — no Docker Hub, no cloud build minutes.
- Console: even the web console is just software reading an API. The Cloudbox Console is ~6k lines of Go over the Kubernetes API — and you'll read its source in module 08 (the Workshop page you've been watching all day is ~100 of them).

Say the tiering honestly: "Core is 00–05 and it's a complete cloud on its own. Everything on this second table is for the fast 20% and for your couch tonight — it's all public and nothing later depends on it."
-->

---

# It runs on *practices*, not just tools

<div class="grid grid-cols-2 gap-4 mt-2">
  <div class="practice">
    <strong>GitOps</strong><br>
    Git is the only way anything changes — every change a reviewable commit.
    <div class="mod">module 02 · the loop you'll use all day</div>
  </div>
  <div class="practice">
    <strong>Immutable infrastructure</strong><br>
    No SSH, no drift. The whole machine is one declarative document.
    <div class="mod">module 01 · Talos + Cilium</div>
  </div>
  <div class="practice">
    <strong>Self-service</strong><br>
    Declare what you want; the platform makes it real. Nobody files a ticket.
    <div class="mod">module 04 · Crossplane</div>
  </div>
  <div class="practice">
    <strong>Operators as control loops</strong><br>
    The "managed service" is just software that reconciles toward your intent.
    <div class="mod">module 03 · CloudNativePG</div>
  </div>
</div>

<!--
The bridge from "what" to "how": a cloud isn't a pile of tools, it's a handful of practices, and the tools are just how you embody them. Name each one and tie it to the module where they'll feel it in their hands:

- GitOps — the single control plane. You'll do nothing today by clicking; everything is a commit ArgoCD converges. (module 02)
- Immutable infrastructure — Talos has no shell to log into. The node is cattle described by one config; you never pet it. (module 01)
- Self-service — the 2008 magic: ask for a database, get one, no human in the loop. Crossplane turns one YAML into a whole stack. (module 04)
- Operators as control loops — the insight that demystifies "managed": behind RDS is a control loop, and CloudNativePG is that same loop in your cluster. (module 03)

These four are the transferable skills — the thing they take to work on Monday even if they never run Talos-in-Docker again. The tools change; the practices don't.
-->

---

# Your cloud, in a box

<div class="arch">
  <div class="laptop">
    <div class="band-title"><Logo name="docker" size="1.3rem"/> Your laptop · Docker — the "datacenter"</div>
    <div class="k8s">
      <div class="band-title"><Logo name="talos" size="1.3rem"/> <Logo name="cilium" size="1.3rem"/> Talos + Cilium · Kubernetes — no kube-proxy</div>
      <div class="engine">
        <Logo name="gitea" label size="1.7rem"/> <span class="arrow">→</span> <Logo name="argocd" label="Argo CD" size="1.7rem"/>
        <span class="delivers">delivers everything below as a git commit</span>
      </div>
      <div class="services">
        <Logo name="cloudnativepg" label size="1.6rem"/>
        <Logo name="rustfs" text="RustFS" size="1.6rem"/>
        <Logo name="crossplane" label size="1.6rem"/>
        <Logo name="knative" label size="1.6rem"/>
        <Logo name="nats" label="NATS" size="1.6rem"/>
        <Logo name="argo-workflows" label="CI · Workflows" size="1.6rem"/>
        <Logo name="cloudbox" text="Cloudbox" size="1.6rem"/>
        <Logo name="grafana" label="Victoria + OTel" size="1.6rem"/>
      </div>
    </div>
  </div>
</div>

<div class="story mt-2"><span class="tag">BRUKTBY</span> &nbsp;This is the platform you're migrating them to. You'll see this exact diagram at the end — every box green, their photo pipeline live on top.</div>

<!--
The map of the whole day — the comparison table you just showed, now as one running system. You'll return to this exact diagram in the closing, when every box is up and green across the room. Walk it bottom-up, one layer per beat:

1. Docker on your laptop is the "datacenter".
2. Talos Linux v1.13 nodes run as containers — an immutable, API-only OS purpose-built for Kubernetes (module 01). Cilium does networking in eBPF; there is no kube-proxy in this cluster at all.
3. Gitea + ArgoCD are the heart (module 02): the git server lives IN the cluster, and ArgoCD delivers everything below it from that git repo. Nothing depends on GitHub or the venue WiFi.
4. The platform services: CloudNativePG for managed Postgres, RustFS for S3-compatible object storage (module 03), Crossplane v2 for the self-service API (module 04).
5. The stretch tier: Knative serverless (06), in-cluster CI with BuildKit and the Zot registry (07), the Cloudbox Console portal (08), and observability — the Victoria stack (VictoriaMetrics/Logs/Traces + Grafana) plus the OTel Collector — enabled on-demand as the module 09 capstone, not running from minute one.

Key sentence to land before moving on: "Everything below ArgoCD arrives as a git commit. That's the mechanic you'll use all day."

Don't explain any component deeply here — each gets its own module framing. Now hand over to the mechanics: how today actually works.
-->
