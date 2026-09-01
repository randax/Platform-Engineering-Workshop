# Module 02: your cluster gets a git server and an opinion

## The goal

Your cluster hosts its own git server (Gitea) and its own delivery system (ArgoCD), and
git is the only way anything changes. You prove it by pushing a commit to the in-cluster
repo and watching a namespace and a ConfigMap with your name in it materialize without
you touching `kubectl apply`.

## Why this matters

Everything from here on arrives as a git commit that ArgoCD converges: databases,
platform APIs, serverless. The git server is *inside* the cluster, so your platform
doesn't depend on GitHub or anyone's SaaS. The pattern (app-of-apps:
one root Application that deploys other Applications) is how real platform teams
bootstrap clusters.

## The task

1. Install the machinery and seed the repo:

   ```bash
   mise run gitops:bootstrap   # Gitea + ArgoCD into the cluster
   mise run gitops:seed        # pushes this repository into your in-cluster Gitea
   ```

2. Look around your cloud's control room:
   - Gitea: http://gitea.cloudbox.k8s.test. Log in as `gitea_admin` / `cloudbox123`, find
     the `cloudbox/platform` repo.
   - ArgoCD: http://argocd.cloudbox.k8s.test. Username `admin`; password from the cluster
     (hint 1). Find the root `platform` Application. What path does it watch? What single
     Application did it already create, and why is that dir called "wave 0"?

3. **Make a real change through git.** This move is the write path for every module from
   here on, so learn it once. Clone the repo *from your Gitea* and, using the two
   template files in this lab directory:
   - `demo-app.yaml` → `gitops/apps/demo.yaml` (a new ArgoCD Application)
   - `welcome.yaml` → `gitops/components/demo/welcome.yaml`, with **your name** in `owner`.

   Commit, push, and watch ArgoCD do the rest. When did the `demo` namespace appear? Who
   created it?

4. Try to cheat: `kubectl -n demo edit configmap welcome` and change your name. Wait up
   to ~5 minutes (or press Refresh→Sync in the UI). What happens, and why?

5. Run `./verify.sh`.

## Check your work

```bash
./verify.sh
```

## Hints

<details>
<summary>Hint 1: ArgoCD admin password + finding my way in the UI</summary>

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

In the UI, open the `platform` app. The tree view shows every child Application it
manages. `spec.source.path` (App details → Manifest) is the watched path: `gitops/apps`.
</details>

<details>
<summary>Hint 2: Cloning from your in-cluster Gitea</summary>

```bash
git clone http://gitea_admin:cloudbox123@gitea.cloudbox.k8s.test/cloudbox/platform.git ~/cloudbox-platform
cd ~/cloudbox-platform && mise trust   # untrusted, every mise tool run from here fails
```

Ignore the URL in Gitea's own clone box: it shows the in-cluster `ROOT_URL`, which only
resolves inside the cluster. Use the URL above from your laptop.

This is a *different remote* than github.com: the copy your cluster watches. Pushes to
GitHub change nothing here. (Alternative: `seed-gitea.sh` printed a
`git remote add cloudbox …` line; then it's `git push cloudbox main` from the workshop
checkout.)
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

Then watch: `kubectl get application -n argocd -w` or the UI. ArgoCD polls every ~3 min;
Refresh in the UI skips the wait.
</details>

<details>
<summary>Hint 4: Step 4 "cheating" doesn't get reverted?</summary>

Self-heal reacts to drift when ArgoCD notices it. A UI Refresh on the `demo` app forces
the comparison; the ConfigMap snaps back to the git version. Now reverse the experiment:
which file would you edit to change the name *legitimately*?
</details>

<details>
<summary>Full solution</summary>

```bash
mise run gitops:bootstrap
mise run gitops:seed

WORKSHOP="$(git rev-parse --show-toplevel)"
git clone http://gitea_admin:cloudbox123@gitea.cloudbox.k8s.test/cloudbox/platform.git ~/cloudbox-platform
cd ~/cloudbox-platform && mise trust
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

## Explain-back

Tell your neighbor: who reverted your step-4 edit, and how did it know? (Repo, root app,
demo app, self-heal.)

## Going deeper

- Delete `gitops/apps/demo.yaml` and push. The root app runs with `prune: false` (it
  only ever adds children; auto-pruning once tore namespaces out from under a running
  lab), so delete the Application yourself: `kubectl -n argocd delete application demo`.
  The namespace and ConfigMap survive, orphaned; deletion only cascades with the
  `resources-finalizer.argocd.argoproj.io` finalizer. `git revert` the deletion and the
  orphans get re-adopted. Re-run `./verify.sh` after.
- Read the root app: `kubectl -n argocd get app platform -o yaml`. Find the sync-wave
  annotations on the children. What orders what?
- Observability is not running yet; it's a catalog item you enable in module 09.
