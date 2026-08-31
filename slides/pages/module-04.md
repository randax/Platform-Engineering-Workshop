---
layout: section
transition: view-transition
---

<span class="badge">Module 04 · core</span>

# Self-service: your platform gets an API

<div class="modlogos"><Logo name="crossplane" label size="2.6rem"/> <Logo name="cloudnativepg" label size="2.6rem"/></div>

<div class="story"><span class="tag">BRUKTBY</span> &nbsp;Their app devs get self-service back. One YAML for a database, no ticket to the platform team. The 2008 magic, self-hosted.</div>

<!--
Module 03 made the attendee capable of provisioning databases. This module builds the abstraction so their developers never have to be. Platform engineering at its purest: you define an API, developers consume it.
-->

---

# One resource in, a stack out

```mermaid {scale: 0.7}
flowchart LR
  xr["WorkshopDatabase<br>10-line namespaced XR"] --> comp["Crossplane v2<br>Composition pipeline"]
  comp --> pg["CNPG Cluster"]
  comp --> bucket["S3 bucket (Job)"]
```

- You own **both** sides of the API
- `aws rds create-db-instance`, but yours

<div class="snip">

```yaml
apiVersion: platform.cloudbox.io/v1alpha1
kind: WorkshopDatabase
metadata:
  name: my-db
spec:
  size: small     # one knob: compute, storage, HA instances
```

<span class="snipsrc">lab/04-self-service/examples/my-database.yaml</span>
</div>

<!--
The concept: developers shouldn't need to know CNPG, storage classes, or RustFS endpoints. Platform engineering is building the abstraction. You define WHAT can be asked for (the WorkshopDatabase XRD) and HOW it's fulfilled (a Composition); developers write a 10-line resource.

Crossplane is the machinery: the XR (composite resource) comes in, the composition pipeline runs, and out come real resources, a CNPG Cluster AND a Job that creates the matching S3 bucket. One request, a whole wired stack.

The punchline for the room: this is exactly what `aws rds create-db-instance` is, a small request against an API someone composed into real infrastructure. The difference is that after this module, YOU own both sides of that API.

Lab flow: enable crossplane.yaml from the catalog, ship the two halves of the platform API via git (xrd.yaml, read the schema!, and composition.yaml), confirm the XRD is ESTABLISHED, then switch hats and be the developer: push examples/my-database.yaml and watch the stack unfold.
-->

---

# <span class="svgi i-triangle-alert"></span> Your training data is stale

- This is Crossplane **v2** (2025)
- Claims are **gone**, namespaced XRs instead
- Compositions emit K8s resources **directly**
- See `kind: Claim` or `claimNames`? That's v1
- Your AI assistant almost certainly learned v1

<!--
A headline teaching point, and the first place today where "verify what the assistant says" gets concrete.

Crossplane v2 (GA in 2025) restructured the core model:
- Claims are GONE. In v1 you had cluster-scoped XRs plus namespaced Claims proxying them; in v2 you create namespaced XRs directly. Simpler, but nearly every blog post, tutorial, and Stack Overflow answer out there now describes an API that no longer exists.
- Compositions are pipeline-mode only, and they can emit plain Kubernetes resources DIRECTLY. Ours outputs a CNPG Cluster and a Job with no provider-kubernetes wrapping; in v1 you needed a provider for that.

Field guide for the room: if you (or your AI assistant) see `kind: Claim`, `claimNames` in an XRD, or a top-level `resources:` list in a Composition, you are reading the past. The lab README carries the same warning.

This lands twice: it's a real operational skill (knowing which major version your sources describe), and it foreshadows module 05's theme. Plausible, confident, out-of-date answers are exactly what agents produce when their training data lags the ecosystem.
-->

---

# See it

<figure class="bigshot">
  <img src="/console/new-application-dark.png" alt="The same XR you just authored, rendered as a form. One submit composes a workload, a database and a bucket." />
  <figcaption>The same XR you just authored, rendered as a form. One submit composes a workload, a database and a bucket.</figcaption>
</figure>

<!--
Hold this up while the room works, or come back to it at the walk-through. It is the Console from module 08 showing what they just built, so say plainly that they have not built the Console yet: this is what module 08 gives them a view of.
-->

---

# GO: Module 04

**Outcome:** a 10-line YAML → database + bucket appear.

```bash
# enable crossplane.yaml; ship platform/xrd.yaml + composition.yaml
cd lab/04-self-service && ./verify.sh
```

<span class="badge">20 min</span> · behind? `mise run catch-up 4`

<div class="urls"><span class="ulabel">open when green</span><code>argocd.cloudbox.k8s.test</code></div>

<!--
The task: enable crossplane.yaml from the catalog (installs Crossplane v2, the patch-and-transform function, and the RBAC letting it manage CNPG Clusters and Jobs). Ship the XRD and the Composition from the lab's platform/ dir as a new component via git. Then be the developer: push the 10-line example WorkshopDatabase and watch the XR, the composed CNPG Cluster, and the bucket Job appear.

Watching the stack unfold is the win: kubectl get workshopdatabase, then the Cluster booting, then the Job completing.

Explain-back: "walk your neighbor through what happened between your 10-line YAML and the running Postgres. Name each controller that acted." (ArgoCD delivered it, Crossplane composed it, CNPG realized it.)

Floor note: the classic failure is an XRD that never goes ESTABLISHED because of a schema typo; kubectl describe xrd shows why. And anyone pattern-matching from v1 tutorials will trip exactly as the warning slide predicted. That's a teachable moment, not a bug.

This module's API is load-bearing later: module 08's portal form creates exactly these WorkshopDatabase resources.
-->
