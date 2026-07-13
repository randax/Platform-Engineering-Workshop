# Module 06 (stretch) — Serverless: scale from zero, on your hardware

## The goal

At the end of this module a Knative Service runs on your platform with **zero pods** —
until you `curl` it, at which point a pod cold-starts, answers, and a minute later is
gone again. You prove it by watching the pod count go 0 → 1 → 0 around a 200 response.

## Why this matters

"Serverless" was never about someone else's servers — it's about *not paying for idle*
and *not managing replicas*. Knative Serving is the open-source engine behind most
Kubernetes serverless offerings (including Cloud Run's API): request-driven autoscaling,
revisioned deploys, scale-to-zero. Running it yourself demystifies the single most
magic-looking cloud product there is.

## The task

1. Enable `knative-serving.yaml` from the catalog (installs Knative Serving + the Kourier
   ingress, reachable on NodePort **31080**).
2. Deploy [`hello-ksvc.yaml`](hello-ksvc.yaml) from this lab dir the GitOps way (you know
   where it goes by now). Wait until the ksvc reports `READY True` and note its URL.
3. **The moment.** Arrange two terminals:
   - one watching pods: `kubectl -n demo get pods -w`
   - one to curl through Kourier. Traffic is routed by the `Host` header — figure out
     what host your ksvc got (hint 2), then:
     `curl -H "Host: <that-host>" http://localhost:31080/`

   Watch the first request *create* a pod (cold start — how long did it take?), repeat
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
<summary>Hint 2: The Host header dance</summary>

```bash
kubectl -n demo get ksvc hello -o jsonpath='{.status.url}'    # e.g. http://hello.demo.example.com
```

`example.com` obviously doesn't resolve to your laptop — that's fine. HTTP routing only
needs the header to match:

```bash
curl -H "Host: hello.demo.example.com" http://localhost:31080/
```

(`example.com` is Knative's default domain; a real install would set a real one +
wildcard DNS. Same mechanics.)
</details>

<details>
<summary>Hint 3: Scale-to-zero is taking forever / never happens</summary>

The ksvc sets `autoscaling.knative.dev/window: "30s"` so idle detection is quick, but
scale-to-zero also waits the global grace period (~30s) — total ≈ 1–1.5 min of *no
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
HOST="$(kubectl -n demo get ksvc hello -o jsonpath='{.status.url}' | sed 's|http://||')"

kubectl -n demo get pods -w &          # watcher
curl -H "Host: $HOST" http://localhost:31080/    # cold start!
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

It checks: the knative-serving app is Synced/Healthy and its deployments are up; ksvc
`hello` is Ready; a curl through Kourier (:31080, correct Host header) returns 200 with
the expected body; and — after a quiet period — that the revision has scaled to zero pods
(this check waits up to ~2 minutes, be patient).

## Explain-back

Tell your neighbor: between your `curl` hitting :31080 and a `Hello ...!` coming back
from a pod that didn't exist — what had to happen, in order? (Ingress → ? → pod; who
buffered your request while the pod started?)

## Going deeper

- Deploy a change (edit `TARGET` via git). Knative keeps both revisions — find them
  (`kubectl -n demo get revisions`) and split traffic 50/50 between them in the ksvc spec.
- Load it: `for i in $(seq 1 200); do curl -s -H "Host: $HOST" http://localhost:31080/ & done; wait`
  — watch the autoscaler add pods. What controls the max?
- Set `autoscaling.knative.dev/min-scale: "1"` and explain when you'd pay that cost on
  purpose (hint: what did your first curl's latency look like?).
