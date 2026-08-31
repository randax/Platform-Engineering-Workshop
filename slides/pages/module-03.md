---
layout: section
transition: view-transition
---

<span class="badge">Module 03 · core</span>

# Data services: Postgres + S3, on your terms

<div class="modlogos"><Logo name="cloudnativepg" label size="2.6rem"/> <Logo name="rustfs" label size="2.6rem"/></div>

<div class="story"><span class="tag">BRUKTBY</span> &nbsp;They become their own RDS <em>and</em> S3 team: the listings database and the photo bucket, self-hosted. This module is the discontinuation that forced the move.</div>

<!--
"Managed database" is the single most-bought cloud product, and the thing teams miss most when leaving a hyperscaler. This module makes each attendee the RDS team and the S3 team, for half an hour.
-->

---

# The operator **is** the managed service

- RDS = Postgres + provisioning + failover + backups
- CloudNativePG does exactly that, in-cluster
- Provisioning, failover, backups, as K8s resources
- Same story for S3: RustFS speaks the API
- Less magic than the price tag suggests

<div class="snip">

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: app-db
spec:
  instances: 1
  bootstrap:
    initdb:
      database: app
      owner: app          # CNPG generates the secret "app-db-app"
  storage:
    size: 1Gi
```

<span class="snipsrc">lab/03-data/postgres-cluster.yaml</span>
</div>

<!--
The concept: what you're buying from a hyperscaler's managed database is software that provisions, monitors, fails over, and backs up. A Kubernetes operator like CloudNativePG IS that software: the same control loop that would run behind AWS's console runs in your cluster instead. Declare a Cluster resource, get a supervised Postgres with failover and backup hooks.

CloudNativePG specifically: CNCF project, originally from EDB, arguably the most production-adopted Postgres operator. This isn't a toy pick.

Same story for object storage: S3 is an API, and RustFS implements it: buckets, multipart, presigned URLs. In the lab they'll create a bucket, upload a file, and generate a presigned URL that works in their browser: handing someone a download link with zero AWS involved.

Everything arrives via the module-02 loop: enable cnpg-operator and rustfs from the catalog, then deliver a Cluster manifest through the demo component in git. psql into your own DBaaS is the visible win.
-->

---

# Interlude: the MinIO story

- MinIO: the default self-hosted S3 for a decade
- 2025–26: open-source edition **discontinued**
  - console gutted, binaries stopped, repo archived
  - focus moved to proprietary AIStor
- The AGPL code didn't change; it just stopped
- RustFS: independent Apache-2.0 **alternative**

<!--
The honest-ecosystem interlude. This audience fact-checks, so say it precisely:

MinIO was THE self-hosted S3 answer for a decade. Through 2025–26, its open-source community edition was discontinued: the management console was gutted in May 2025, community binary releases stopped in October 2025, and the repo was archived in April 2026 (still AGPL, but no longer developed) as the company focused on its proprietary AIStor product.

Two things NOT to say, because they're wrong: MinIO did not "go proprietary" or "relicense". The AGPL code is still AGPL; it was discontinued, not relicensed. And RustFS is not "the successor"; it's an independent reimplementation under Apache 2.0 that happens to speak the same S3 API.

Why we chose RustFS anyway, with eyes open: Apache-2.0 license, ~90 MB idle footprint, presigned GET/PUT work. It's young (1.0 still in beta, a rough CVE history through late 2025), acceptable for an ephemeral lab sandbox, and we say so out loud. Alternatives worth knowing: SeaweedFS (our rehearsed plan B), Garage, Ceph/Rook at scale.

The meta-lesson connects back to the "why" section: the roadmap risk from slide 3 isn't cloud-only. It applies to the open-source supply chain too. Owning your platform includes owning the choice of what replaces a discontinued dependency.
-->

---

# See it

<figure class="bigshot">
  <img src="/console/buckets-dark.png" alt="The other half of this module: your own S3, with the RustFS pod behind it. Seen from the Console you build in module 08." />
  <figcaption>The other half of this module: your own S3, with the RustFS pod behind it. Seen from the Console you build in module 08.</figcaption>
</figure>

<!--
Hold this up while the room works, or come back to it at the walk-through. It is the Console from module 08 showing what they just built, so say plainly that they have not built the Console yet: this is what module 08 gives them a view of.
-->

---

# GO: Module 03

**Outcome:** `psql` into your own DBaaS; a presigned URL that works.

```bash
# enable cnpg-operator.yaml + rustfs.yaml from the catalog
cd lab/03-data && ./verify.sh
```

<span class="badge">20 min</span> · behind? `mise run catch-up 3`

<div class="urls"><span class="ulabel">open when green</span><code>s3.cloudbox.k8s.test</code></div>

<!--
The task in three beats, all through the git loop from module 02:
1. Enable cnpg-operator.yaml and rustfs.yaml from the catalog (copy → commit → push).
2. Deliver the provided CNPG Cluster manifest (app-db) into the demo namespace via the repo; wait for "Cluster in healthy state"; get a psql prompt inside it and run SELECT 1.
3. RustFS speaks S3 at http://s3.cloudbox.k8s.test (access key cloudbox / secret cloudbox123): create a bucket, upload a file, generate a presigned URL, open it in the browser.

Wins to celebrate: the psql prompt (module win #1) and a presigned URL opening in a browser (win #2: "you just handed out a download link with zero AWS").

Floor notes: the most common stall is pushing the Cluster manifest to the wrong directory; the README asks "where did module 02 put demo-namespace manifests?" on purpose. Presigned URL failures are usually a clock-skew or wrong-endpoint issue; hints cover both.

BREAK after this module: 10 minutes, and the day's only scheduled one (from the pivot onward the room is self-paced). Announce it now so people pace themselves.
-->

---
layout: fact
---

# Break

10 minutes. Back at `:XX`

<!--
First break, roughly the 2-hour mark. Fill in the actual return time on the projector (or say it twice).

While people are away, this is a good moment to bring the Cloudbox Console's Workshop page up on the projector; by now most rows for 00–03 should be turning green across the room.

Split the break: one of us does the projector prep below, the other sweeps for red stickies. Break time is catch-up time, and catch-up.sh 3 gets anyone fully current in ~2 minutes.

No projector prep needed during this break any more: the Backstage demo is a screenshot now, so nothing has to be warmed. Use the time to sweep for red stickies.
-->
