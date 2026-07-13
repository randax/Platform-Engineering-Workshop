# Module 08 (stretch) — Backstage: a front door for your platform

## The goal

At the end of this module your platform has a developer portal: Backstage running at
http://localhost:30700, its catalog listing your platform's components, and — the full
loop — a software template that scaffolds a new app into a fresh Gitea repo and hands it
to ArgoCD. You prove the base outcome with `./verify.sh`; the template loop is the trophy.

## Why this matters

Everything you built so far is APIs and YAML — perfect for platform engineers, invisible
to everyone else. A portal is how a platform gets *adopted*: catalog ("what exists, who
owns it"), templates ("new service, golden path, one form"), and plugins surfacing ArgoCD
status next to the code. Backstage (CNCF) is the de-facto standard; we run the CNOE
prebuilt image, which comes wired for exactly our Gitea + ArgoCD combo.

> **RAM & rehearsal note:** Backstage is the heaviest single component (~1.5–2 GB, plus
> its Postgres) — that's why it's last. On a 16 GB machine consider stopping something
> first (module 07's builds, for instance). If the template step misbehaves, that's what
> the presenter's instance on the projector is for — watch the loop there, run the
> catalog part locally.

## The task

1. Enable `backstage.yaml` from the catalog. This one takes a few minutes — it also
   brings its own Postgres. Watch `kubectl -n backstage get pods`.
2. Open http://localhost:30700 and sign in as **guest**.
3. Explore the catalog: which of the things *you built today* does it already know about?
   Where does that knowledge come from (what feeds a Backstage catalog)?
4. **The loop:** Create → choose the app template → fill the form → run it. Then chase
   what it did: a new repo in Gitea (http://localhost:30300), a new Application in ArgoCD
   (http://localhost:30080), and eventually pods. One form → running service, entirely
   inside your laptop.
5. Run `./verify.sh`.

## Hints

<details>
<summary>Hint 1: Enabling, and what "up" looks like</summary>

```bash
cd ~/cloudbox-platform
cp gitops/catalog/backstage.yaml gitops/apps/
git add . && git commit -m "enable backstage" && git push
kubectl -n backstage get pods -w    # backstage + postgres; first boot is the slowest
```

It's ready when `curl -s http://localhost:30700` returns HTML instead of nothing.
</details>

<details>
<summary>Hint 2: Where the catalog content comes from</summary>

Backstage reads `catalog-info.yaml` entities from configured locations — the CNOE image
is preconfigured to read from your Gitea. Check its config:
`kubectl -n backstage get configmap -o name`, then look for `app-config` and its
`catalog.locations` section. That's the answer to task 3.
</details>

<details>
<summary>Hint 3: The template ran but nothing deployed?</summary>

Follow the chain in order — the template does three separate things:
1. Gitea: does the new repo exist and contain the scaffolded code + manifests?
2. ArgoCD: did an Application get created for it? Is it Synced?
3. Cluster: `kubectl get pods -n <new-app-namespace>`.

The step that broke names the integration that needs attention (Gitea token, ArgoCD
credentials — both preconfigured in the CNOE image, but the projector fallback exists
for a reason).
</details>

<details>
<summary>Full solution</summary>

```bash
cd ~/cloudbox-platform
cp gitops/catalog/backstage.yaml gitops/apps/
git add . && git commit -m "module 08: enable backstage" && git push

kubectl -n backstage rollout status deploy/backstage --timeout=600s
open http://localhost:30700    # guest sign-in

# UI: Create → template → name it "my-first-portal-app" → Run
# then verify the chain:
#   http://localhost:30300  → new repo exists
#   http://localhost:30080  → new Application synced
#   kubectl get pods -A | grep my-first-portal-app

cd "$(git rev-parse --show-toplevel)/lab/08-portal" && ./verify.sh
```
</details>

## Check your work

```bash
./verify.sh
```

It checks: the backstage app is Synced/Healthy; the Backstage deployment (and its
Postgres) are ready; the UI answers on :30700; and the catalog API responds (portal
actually functional, not just a pod that's Running). The template loop is verified by
your own eyes — it's UI-driven and named by you, so the script can't chase it.

## Explain-back

Tell your neighbor: trace the template run end to end — form → Gitea → ArgoCD → pods.
Which credentials/integrations had to exist for each arrow? (That wiring — not the UI —
is the actual work of running a portal.)

## Going deeper

- Add one of *today's* components to the catalog by hand: write a `catalog-info.yaml`
  for `hello-site` or your WorkshopDatabase XRD, push it to Gitea, register it in the UI.
- Find the ArgoCD plugin card on a component page. Where does Backstage get live sync
  status from?
- The real question to take home: your platform now has an API (module 04) *and* a
  portal (module 08). For your team — which one is the product, and which one is the
  view? Argue both ways.
