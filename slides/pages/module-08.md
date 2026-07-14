---
layout: section
---

<span class="badge">Module 08 · stretch · self-paced + demo</span>

# The Cloudbox Console: a portal you can read

<!--
The portal module — and the second honest-ecosystem interlude of the day (build vs. buy). Everything built so far is APIs and YAML: perfect for platform engineers, invisible to everyone else. A portal is how a platform gets adopted.
-->

---

# A portal is just REST calls

- ~730 lines of Go + htmx. That's all
- Reads the K8s API with a ServiceAccount token
- Read-only role on exactly four resources
- The DB form? Creates a `WorkshopDatabase`
- Module 04 already did the hard part

<!--
Demystification slide. The industry reflex is "portal = Backstage = big adoption project". But mechanically, a portal is a web app making REST calls to the Kubernetes API — and the Cloudbox Console proves it in ~730 lines of Go and htmx (one vendored .js file, no build step).

Walk the architecture in one breath: kube.go authenticates with nothing but the pod's mounted ServiceAccount token; a read-only ClusterRole covers exactly the four resource types it renders (check it: kubectl describe clusterrole portal-read); resources.go lists ArgoCD Applications, CNPG Clusters, and Knative Services as dynamic resources; handlers.go's "New database" form POST builds a WorkshopDatabase object and creates it — about 20 lines that replace a whole portal product's scaffolder, because module 04's XRD and Composition already did the hard part.

That's the lesson stated on the slide: the portal has no special powers. Your platform already had the API; the portal is a form in front of it.

The star task in the lab: create console-db through the form, then prove it's real the module-04 way — kubectl get workshopdatabase, then watch the composed CNPG cluster boot. And the follow-up worth savoring: this database did NOT go through git (check who created it, and note it's absent from Gitea). Governance question for the explain-back: should a portal write to git instead? Real platform teams argue about exactly this.
-->

---
layout: two-cols
---

# Build…

- Small platform, known audience
- One screen fits everything
- Every line readable in an evening
- No standing team required

::right::

# …or buy (Backstage)

- Plugin ecosystem: hundreds of integrations
- Catalog + ownership at org scale
- TechDocs, golden-path templates
- Costs: ~2 GB, YAML, an owning team

<!--
The build-vs-buy interlude — be honest in both directions, because "bespoke always" is as wrong as "Backstage by default".

Bespoke won HERE because the platform is small and the audience is the builder: everything fits on one screen, the source is readable over coffee, and there's no team to staff. Those conditions are real in small orgs and internal tools — and they're exactly the conditions that vanish at scale.

Backstage earns its weight when you need: the plugin ecosystem (ArgoCD, PagerDuty, Sonar, cost insights — integrations you'd otherwise write AND maintain), a catalog with real ownership metadata across dozens of teams and hundreds of services, and TechDocs/scaffolder golden paths with an ecosystem behind them.

The costs are real too: roughly 2 GB of Node.js plus a Postgres, YAML-heavy configuration, and — the big one — typically a team that owns it. The closing line, verbatim from the lab: a portal is a PRODUCT decision, not a default.

Next slide: we look at Backstage live, so this isn't a straw man.
-->

---

# Interlude: Backstage, live

<div class="callout mt-2 mb-4">Presenter demo · ~5 min · watch the projector</div>

- Catalog → template → new Gitea repo
- → ArgoCD app → running pods
- The template's glue is the real work
- `backstage.yaml` stays in the catalog — try at home

<!--
Presenter demo, ~5 minutes, on the projector cluster (backstage.yaml was pre-enabled during the second break — first boot is slow: ~2 GB CNOE image plus a CNPG database, which is precisely why this is a demo and not the hands-on).

The loop to show: guest sign-in at :30700 → catalog entities fed from Gitea → run a software template → chase the result through Gitea (:30300, a new repo appeared) → ArgoCD (:30080, a new Application) → pods running.

Narrate what to watch for: the template wires together git, CI/CD, and the catalog — that integration glue is the real, ongoing work of operating Backstage. The demo is deliberately placed AFTER attendees built the same self-service loop themselves in 04 and saw it fronted by a form minutes ago: same shape, industrial strength, industrial weight.

backstage.yaml stays in the catalog — anyone with RAM to spare can run this exact loop at home. That's the fair test of the build-vs-buy slide.
-->

---

# GO — Module 08

**Outcome:** a database created from a form — provably real.

```bash
# enable portal.yaml → open http://localhost:30600
cd lab/08-portal && ./verify.sh
```

<span class="badge">~20 min</span> · then read the source: `apps/portal/`

<!--
The task: enable portal.yaml (lands in ns portal in seconds — one small Go binary), explore the Console at :30600, and for each page answer "which Kubernetes API is this?" — they installed every one of them today.

Star task: create console-db (size small) via the New database form, then prove it with kubectl: the WorkshopDatabase XR, and the composed CNPG cluster booting with -w. Then the governance question: this one didn't go through git — find the evidence, keep the thought for the explain-back.

Finish by actually reading the source — apps/portal/ is five Go files and four templates; ask them to find the 20 lines behind the form. "After today you can read every line of your platform's front door" is the sentence to leave hanging.

Also point out the Workshop page they've been watching all day lives in this same binary (workshop.go) — a checklist inferred from live cluster state, ~100 lines.
-->
