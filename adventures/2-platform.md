# Door 2 — Platform: extend the platform itself

**You came for:** the platform engineer's core move — taking a raw open-source
component and turning it into a *capability*: packaged, delivered by git,
discoverable in the catalog, ideally self-service.

**Prerequisites:** module 02 (GitOps). Module 04 (Crossplane) unlocks the last
level. `./scripts/catch-up.sh 4` covers both.

## The mission

Every capability on this platform is the same shape: manifests in
`gitops/components/<x>/`, one ArgoCD Application in `gitops/catalog/<x>.yaml`,
one namespace, a sync wave. Attendees enabled them all day by copying catalog
files. Now *author* one — that's the difference between using a platform and
building one.

## Warm-up (~15 min)

Read one component end to end — `gitops/components/nats/` is small and
hand-written. Find: where the namespace is declared, what the catalog entry's
`sync-wave` annotation does, why `VENDOR.md` exists (it records what upstream
artifact the manifests came from, so pin bumps stay honest). This anatomy is
your template.

## The build — tiered by machine

**16 GB tier — cert-manager.** The classic first platform add: three small
deployments, negligible RAM, and every later capability wants TLS.
1. Vendor the upstream static manifest into `gitops/components/cert-manager/`
   (record the version + source in a `VENDOR.md`), write
   `catalog/cert-manager.yaml`, enable it. It's CRD-heavy: you'll want
   `ServerSideApply=true` — find another catalog entry that already sets it and
   see why.
2. Create a self-signed `ClusterIssuer`, then a `Certificate` for the Console,
   and watch the secret appear. TLS on a NodePort is underwhelming alone —
   pair with door 4's Gateway API for the real payoff.

**32 GB tier — Kafka (Strimzi).** The heavyweight-operator experience, eyes
open: you already have durable messaging (NATS, module 10 / PRD-0001), so this
door is about what operating Kafka *costs*, which is exactly what a platform
team must know before saying yes to it.
1. Strimzi operator as a component, then a single-node KRaft `Kafka` +
   `KafkaNodePool`. **Cap the heap** — `-Xmx512m`, ~1 GiB pod limit — the
   worker container has 6 GiB for everything.
2. Produce and consume with the console tools already in the broker image
   (`kubectl exec` — no new images).
3. Compare, honestly, with the NATS component you read in the warm-up: images,
   RAM, CRDs, moving parts. Write the one-paragraph platform-team verdict:
   when is Kafka worth it?

**The apex — make it self-service.** A component only platform *engineers* can
use isn't self-service. Module 04 style: a namespaced `Topic`
XR whose composition creates a `KafkaTopic` (Strimzi CRD) — or, NATS-flavored,
a `Queue` XR that provisions a JetStream stream. One YAML from a product team →
a queue appears. That's the whole job, miniaturized.

## You know it works when…

- Your catalog entry syncs green in ArgoCD with **no manual `kubectl apply`
  anywhere** — git was the only write path.
- cert-manager: `kubectl get certificate -A` shows Ready and the secret holds a
  cert with your issuer.
- Kafka: a message produced before deleting the broker pod is consumed after it
  returns.
- Apex: a `Topic`/`Queue` XR from a *different* namespace materializes the real
  resource.

## Known traps

- **Offline first**: the venue network is not your friend. Anything you deploy
  must have its images in the mirror (`scripts/images.txt`) or already on your
  machine. The cert-manager/Strimzi images ship in the final prework refresh —
  if `crane manifest --insecure localhost:5001/<image>` (docker) / `tbx cache warm --check`
  (tbx) can't find them, you're
  on the online path; consider the NATS-flavored apex instead (zero new
  images).
- One namespace per component, declared in the component's own manifests —
  that's the repo convention, and drift from it is what
  `check-consistency.sh` hunts.
- CRDs + the Application health check: ArgoCD shows Progressing forever if a
  CRD-heavy app lacks `ServerSideApply=true`.
- Sync waves order the *catalog*, not resources inside your component — inside,
  use `argocd.argoproj.io/sync-wave` per resource if ordering bites you.
- Strimzi's operator takes ~a minute before it even looks at your `Kafka` CR.
  Patience before debugging.

## At home

Vendor a component nobody chose today — Keycloak, external-secrets, a Valkey
operator — and take it all the way to an XR. The catalog mechanic is the
platform's extension API; it doesn't care what you feed it.
