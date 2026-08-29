# Module 06 (stretch) — Serverless: scale from zero, on your hardware

## The goal

At the end of this module a Knative Service runs on your platform with **zero pods**
until you `curl` it, at which point a pod cold-starts, answers, and a minute later is
gone again. You prove it by watching the pod count go 0 → 1 → 0 around a 200 response.

## Why this matters

"Serverless" was never about someone else's servers. It's about *not paying for idle*
and *not managing replicas*. Knative Serving is the open-source engine behind most
Kubernetes serverless offerings (including Cloud Run's API): request-driven autoscaling,
revisioned deploys, scale-to-zero. Running it yourself demystifies the single most
magic-looking cloud product there is.

## The task

1. Enable `knative-serving.yaml` from the catalog (installs Knative Serving + the Kourier
   gateway behind the Cilium ingress).
2. Deploy [`hello-ksvc.yaml`](hello-ksvc.yaml) from this lab dir the GitOps way (you know
   where it goes by now). Wait until the ksvc reports `READY True` and note its URL.
3. **The moment.** Arrange two terminals:
   - one watching pods: `kubectl -n demo get pods -w`
   - one to curl the ksvc URL: `curl "$(kubectl -n demo get ksvc hello -o jsonpath='{.status.url}')/"`

   Watch the first request *create* a pod (cold start: how long did it take?), repeat
   requests hit it warm, and ~60–90s of silence make it disappear.
4. Run `./verify.sh`.

## Hints

<details>
<summary>Hint 1: Enabling + delivering, condensed</summary>

In your Gitea clone:

```bash
cp gitops/catalog/knative-serving.yaml gitops/apps/
cp <workshop-repo>/lab/06-serverless/hello-ksvc.yaml gitops/components/demo/
git add . && git commit -m "knative + hello service" && git push
```

Knative's webhooks take a minute to come up; the demo app retries. Watch:
`kubectl -n knative-serving get pods` and `kubectl -n demo get ksvc -w`.
</details>

<details>
<summary>Hint 2: Find the ksvc URL</summary>

```bash
kubectl -n demo get ksvc hello -o jsonpath='{.status.url}'
```

The URL is in the `kn.cloudbox.k8s.test` domain and routes through the Cilium ingress:

```bash
curl "$(kubectl -n demo get ksvc hello -o jsonpath='{.status.url}')/"
```

The host is `<ksvc>-<namespace>.kn.cloudbox.k8s.test`, here `hello-demo.kn.cloudbox.k8s.test`.
That dash is not cosmetic: it keeps every ksvc one DNS label under the domain, and a
Kubernetes Ingress wildcard host matches exactly one label. That is what lets a single
`*.kn.cloudbox.k8s.test` rule serve every namespace anyone invents. Ask the cluster rather
than assuming, though: `.status.url` is the published truth.

On the **docker** substrate `/etc/hosts` cannot hold a wildcard, so only the ksvc names
`install.sh --print-hosts` lists resolve. For a ksvc you invent yourself, teach it the
name: `./scripts/install.sh --add-hosts <first label>`, e.g. `--add-hosts hello-demo`.
It remembers it, so a later rewrite of the block keeps it. Or skip the name entirely:
`curl -H "Host: <the ksvc host>" http://localhost/`. On **tbx** the resolver answers the
wildcard, so anything you create just works.
</details>

<details>
<summary>Hint 3: Scale-to-zero is taking forever / never happens</summary>

The ksvc sets `autoscaling.knative.dev/window: "30s"` so idle detection is quick, but
scale-to-zero also waits the global grace period (~30s): total ≈ 1–1.5 min of *no
requests*. Watch the decision-maker directly:
`kubectl -n knative-serving logs deploy/autoscaler --tail=20`. And make sure no terminal
is still curling in a loop.
</details>

<details>
<summary>Full solution</summary>

```bash
WORKSHOP="$(git rev-parse --show-toplevel)"
cd ~/cloudbox-platform
cp gitops/catalog/knative-serving.yaml gitops/apps/
cp "$WORKSHOP/lab/06-serverless/hello-ksvc.yaml" gitops/components/demo/
git add . && git commit -m "module 06: knative + hello ksvc" && git push

kubectl -n demo get ksvc hello -w      # until READY True
URL="$(kubectl -n demo get ksvc hello -o jsonpath='{.status.url}')"

kubectl -n demo get pods -w &          # watcher
curl "${URL}/"                         # cold start!
sleep 90                                # silence...
kubectl -n demo get pods                # gone again
kill %1

cd "$WORKSHOP/lab/06-serverless" && ./verify.sh
```
</details>

## Check your work

```bash
./verify.sh
```

It checks: the knative-serving app is Healthy (Synced is the happy path; sync is advisory) and its deployments are up; ksvc
`hello` is Ready; a curl through the Cilium ingress returns 200 with
the expected body; and, after a quiet period, that the revision has scaled to zero pods
(this check waits up to ~2 minutes, be patient).

## Explain-back

Tell your neighbor: between your `curl` hitting the ksvc URL and a `Hello ...!` coming back
from a pod that didn't exist, what had to happen, in order? (Ingress → ? → pod; who
buffered your request while the pod started?)

## Going deeper

- Deploy a change (edit `TARGET` via git). Knative keeps both revisions. Find them
  (`kubectl -n demo get revisions`) and split traffic 50/50 between them in the ksvc spec.
- Load it: `for i in $(seq 1 200); do curl -s "${URL}/" & done; wait`
  and watch the autoscaler add pods. What controls the max?
- Set `autoscaling.knative.dev/min-scale: "1"` and explain when you'd pay that cost on
  purpose (hint: what did your first curl's latency look like?).
