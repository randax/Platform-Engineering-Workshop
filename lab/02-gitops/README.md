# Module 02 — GitOps: your cluster gets a git server and an opinion

## The goal

At the end of this module your cluster hosts its own git server (Gitea) and its own
delivery system (ArgoCD), and **git is the only way anything changes**. You prove it by
pushing a commit to the in-cluster repo and watching a namespace and a ConfigMap — with
your name in it — materialize without you touching `kubectl apply`.

## Why this matters

This is the architectural heart of the workshop. Everything from here on — databases,
platform APIs, serverless — arrives as a git commit that ArgoCD converges. Note the git
server is *inside* the cluster: your platform doesn't depend on GitHub, on the venue WiFi,
or on anyone's SaaS. That's "cloud on your terms" in one design decision. The pattern
(app-of-apps: one root Application that deploys other Applications) is exactly how real
platform teams bootstrap clusters.

## The task

1. Install the machinery and seed the repo:

   ```bash
   ./scripts/bootstrap-gitops.sh   # Gitea + ArgoCD into the cluster
   ./scripts/seed-gitea.sh         # pushes this repository into your in-cluster Gitea
   ```

2. Look around your cloud's control room:
   - Gitea: http://localhost:30300 — log in as `gitea_admin` / `cloudbox123`, find the
     `cloudbox/platform` repo.
   - ArgoCD: http://localhost:30080 — username `admin`; get the password from the cluster
     (hint 1). Find the root `platform` Application. What path in the repo does it watch?
     What single Application did it already create, and why is that dir called "wave 0"?

3. **Make a real change through git.** Clone the repo *from your Gitea* and, using the two
   template files in this lab directory:
   - `demo-app.yaml` → `gitops/apps/demo.yaml` (a new ArgoCD Application for your own stuff)
   - `welcome.yaml` → `gitops/components/demo/welcome.yaml` — put **your name** in `owner`.

   Commit, push, and watch ArgoCD do the rest. When did the `demo` namespace appear? Who
   created it?

4. Try to cheat: `kubectl -n demo edit configmap welcome` and change your name to something
   else. Wait up to ~5 minutes (or press Refresh→Sync in the UI). What happens, and why?

5. Run `./verify.sh`.

## Hints

<details>
<summary>Hint 1: ArgoCD admin password + finding my way in the UI</summary>

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

In the UI, open the `platform` app — the tree view shows every child Application it
manages. `spec.source.path` (App details → Manifest) is the watched path: `gitops/apps`.
</details>

<details>
<summary>Hint 2: Cloning from your in-cluster Gitea</summary>

```bash
git clone http://gitea_admin:cloudbox123@localhost:30300/cloudbox/platform.git ~/cloudbox-platform
cd ~/cloudbox-platform
```

This is a *different remote* than github.com — it's the copy your cluster watches. Pushes
to GitHub change nothing on your machine; pushes here change everything. (Alternative:
`seed-gitea.sh` printed a `git remote add cloudbox …` line — you can push to your Gitea
from the workshop checkout instead of cloning; then it's `git push cloudbox main`.)
</details>

<details>
<summary>Hint 3: The change itself</summary>

```bash
cd ~/cloudbox-platform
cp <workshop-repo>/lab/02-gitops/demo-app.yaml gitops/apps/demo.yaml
mkdir -p gitops/components/demo
cp <workshop-repo>/lab/02-gitops/welcome.yaml gitops/components/demo/welcome.yaml
$EDITOR gitops/components/demo/welcome.yaml    # your name in 'owner'
git add . && git commit -m "demo app: welcome configmap" && git push
```

Then watch: `kubectl get application -n argocd -w` or the UI. ArgoCD polls every ~3 min —
the Refresh button in the UI (or `argocd app sync`) skips the wait.
</details>

<details>
<summary>Hint 4: Step 4 "cheating" doesn't get reverted?</summary>

Self-heal reacts to drift when ArgoCD notices it — a UI Refresh on the `demo` app forces
the comparison immediately. The ConfigMap snaps back to the git version. Now reverse the
experiment: which file would you edit to change the name *legitimately*?
</details>

<details>
<summary>Full solution</summary>

```bash
./scripts/bootstrap-gitops.sh
./scripts/seed-gitea.sh

WORKSHOP="$(git rev-parse --show-toplevel)"
git clone http://gitea_admin:cloudbox123@localhost:30300/cloudbox/platform.git /tmp/platform
cd /tmp/platform
cp "$WORKSHOP/lab/02-gitops/demo-app.yaml" gitops/apps/demo.yaml
mkdir -p gitops/components/demo
sed 's/CHANGE ME/Ada Lovelace/' "$WORKSHOP/lab/02-gitops/welcome.yaml" \
  > gitops/components/demo/welcome.yaml
git add . && git commit -m "demo app with welcome configmap" && git push

# watch it land (ArgoCD polls ~3min; force it via UI Refresh if impatient)
kubectl -n argocd get applications -w   # until demo is Synced/Healthy
kubectl -n demo get configmap welcome -o yaml
```
</details>

## Check your work

```bash
./verify.sh
```

It checks: Gitea answers on :30300 and hosts `cloudbox/platform`; ArgoCD answers on
:30080; the root `platform` app points at your in-cluster Gitea (not GitHub) and is
Healthy (Synced is the happy path; sync is advisory); the wave-0 app (storage) is
healthy; and your `demo`
app delivered the `welcome` ConfigMap with a real name in it.

## Explain-back

Tell your neighbor: in step 4 your manual edit was reverted. Walk through *who* reverted
it and *how it knew* — repo, root app, demo app, self-heal. Bonus: why is the git server
being in-cluster a sovereignty feature and not just a demo trick?

## Going deeper

- Observability isn't running yet — it's an on-demand capability you enable later from the
  catalog (`gitops/catalog/grafana.yaml` plus the `victoria-*` and `otel-collector` items),
  not part of wave 0. You'll switch it on and find Grafana in the capstone (module 09).
- Delete `gitops/apps/demo.yaml` from the repo, push, and watch prune remove the `demo`
  *Application object* — then look again: the namespace and ConfigMap are still there,
  **orphaned**. Deleting an Application doesn't cascade to its resources unless the
  Application carries the `resources-finalizer.argocd.argoproj.io` finalizer. Then revert
  the commit — GitOps rollback is `git revert`, and the orphans get re-adopted.
  (Re-run `./verify.sh` after!)
- Read the root app's manifest: `kubectl -n argocd get app platform -o yaml`. Find the
  sync-wave annotations on the children. What orders what?

## AI assistants welcome

Good module for it: ask your assistant to explain any manifest you push before you push it
— "what will ArgoCD do when this lands?" is exactly the review muscle GitOps needs.
