# PRD-0003 — Golden-path `Application` XR (build your own Nais)

**Status:** Proposed (headline feature) · **Verdict:** Build — woven across platform, console & slides
**Depends on:** Crossplane v2 (module 04) · CloudNativePG + RustFS (03) · Knative Serving + sslip.io routing (06) · NATS JetStream ([PRD-0001](0001-durable-messaging-nats.md), built first)
**Inspiration:** [Nais](https://nais.io) `Application`, Humanitec, Heroku, Backstage golden paths

## Problem

The self-service arc peaks too early. Module 04 hands attendees a `WorkshopDatabase`
XR — one YAML in, a managed Postgres + bucket out — and it's the highlight of the
day. But a real internal developer platform (IDP) doesn't stop at a database: you
declare a whole **application** — image, URL, database, bucket, queue — and the
platform provisions and wires all of it. That is exactly what Nais gives Norwegian
public-sector teams, what Humanitec/Heroku sell, and what Backstage golden-path
templates scaffold. The workshop teaches every ingredient (Crossplane compositions,
CNPG, RustFS, Knative, NATS) but never assembles them into the one abstraction that
makes a platform feel like a *product*. This closes that gap.

## Goal & non-goals

**Goal:** a single namespaced `Application` XR that composes a running, URL-addressable
workload with its declared dependencies (Postgres, bucket, queue) and wires their
credentials in — the "one manifest → whole app" golden path. Reuse existing
compositions; add no new heavyweight components. Prove it by **redeploying the
picture-pipeline capstone as `Application`s** (dogfooding), and surface it in the
console and slides as the apex of the self-service story.

**Non-goals:** replacing Knative/Crossplane with a bespoke controller; matching Nais
feature-for-feature (no access policies, no maskinporten, no rollout strategies);
teaching Crossplane composition *authoring* as a hands-on lab (attendees *use* the
XR; reading the composition is optional depth).

## Design

**The XR (namespaced, Crossplane v2 — claims are gone):**

```yaml
apiVersion: platform.cloudbox.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: demo
spec:
  image: ghcr.io/randax/cloudbox-uploader:v0.1.0
  ingress: my-app.127.0.0.1.sslip.io   # optional; omit for cluster-local only
  replicas: { min: 0, max: 3 }         # scale-to-zero by default (Knative)
  database: true                        # → a WorkshopDatabase (CNPG cluster + bucket-less)
  bucket: true                          # → an S3 bucket in RustFS
  queue: true                           # → a NATS JetStream stream (PRD-0001)
  env:                                  # plain extra env
    - { name: LOG_LEVEL, value: info }
```

**Composition pipeline emits, in one reconcile:**
1. a **Knative Service** for the workload (free scale-to-zero + a real
   `*.127.0.0.1.sslip.io` URL via Kourier — no new ingress component needed);
2. a **`WorkshopDatabase`** XR when `database: true` — *composition of compositions*,
   reusing module 04's CNPG path verbatim (this is the "add in CNPG" you asked for);
3. an **S3 bucket** (the existing bucket-Job pattern) when `bucket: true`;
4. a **NATS stream** when `queue: true` (once PRD-0001 lands);
5. **credential wiring** — the DB connection secret, S3 keys, and NATS URL are
   injected into the workload's env, so the app boots already connected. This is the
   part that makes it feel like magic and is the real teaching beat.

**Ingress — two tiers (you flagged nip.io/sslip.io):**
- *App URLs (free):* because the workload is a Knative Service, `spec.ingress`
  just sets the route host; Kourier + sslip.io already serve
  `my-app.demo.127.0.0.1.sslip.io` at `:31080`. No new component.
- *Platform-service URLs (optional polish, separable):* give ArgoCD/Gitea/console
  real hostnames instead of NodePorts via **Cilium Gateway API** (Cilium is already
  the CNI — keeps the eBPF story intact). Tracked as a stretch, not required for the
  golden path.

**Dogfooding — the capstone becomes the proof:** re-express the picture pipeline as
Applications. `uploader` and `resizer` stop being hand-written ksvc/Broker/Trigger
YAML and become two `Application`s (`bucket: true`, `queue: true`); the eventing glue
the golden path can't yet model (Broker/Trigger) stays explicit for now, or becomes a
future `spec.subscribe`. The capstone demo *is* the golden-path demo.

**Console:** a **"New Application"** page mirroring the existing "New database" form,
plus **templates** — golden-path presets ("Web app + Postgres", "Worker + queue + bucket",
"Static site") that pre-fill the form. Same ~20-lines-of-Go pattern as the DB form.

**Slides:** the golden path becomes the climax of the self-service thread — the
`Application` XR next to a Nais manifest, and a new comparison-table row
(*IDP / golden path → Nais · Humanitec · Heroku · Backstage → your `Application` XR*).

## Cost

- **RAM/components:** ~zero new — reuses CNPG, RustFS, Knative, NATS. Cilium Gateway
  (optional tier) is a config flag on the existing Cilium, not a new pod.
- **Time:** the XRD + composition function pipeline is the real build effort
  (composition-of-compositions + secret wiring is the tricky part). Console form and
  slides are small. Rehearsal-in-CI must cover the new `Application` end-to-end.
- **Workshop clock:** *woven in, not a new 35-min lab* — attendees meet it in the
  capstone (deploy an app via `Application`, get a URL) and in the console; the deep
  composition internals are take-home. Keeps the 240-min budget.

## Risks

- **Composition-of-compositions** in Crossplane v2 (an Application XR that creates a
  WorkshopDatabase XR) needs care — readiness propagation and the function pipeline
  order. Prototype this first; it's the make-or-break.
- **Secret wiring** timing: the app must not boot before its DB secret exists —
  Knative revision + `initialScale` or a readiness gate handles it.
- **Scope creep toward "real Nais"** — resist; the teaching win is the *shape*, not
  feature parity.
- **Rehearsal coverage** — add an `Application` end-to-end to bootstrap-test before
  calling it done (the picture-pipeline-as-Applications run covers this).

## Decision

**Build it as the platform's headline abstraction**, in this order:
1. Land NATS (PRD-0001) as a standalone primitive.
2. Prototype the `Application` XRD + composition (workload + CNPG + bucket first,
   then queue + ingress + secret wiring).
3. Redeploy the picture pipeline as `Application`s (dogfood + rehearsal coverage).
4. Console "New Application" form + templates.
5. Slides: golden-path climax + comparison-table row.

Each step is its own reviewable PR.
