# Module 09 (capstone) — The picture pipeline: everything, wired together

## The goal

At the end of this module your platform runs an event-driven picture pipeline: you drop a
photo into the Cloudbox Console's Gallery, and a resizer service *that is not running*
wakes from zero, makes a thumbnail and a metadata file, and goes back to sleep. You prove
it three ways: pods appearing in a `-w` watch, the thumbnail landing in the gallery and
in S3, and — the flourish — the whole chain as a single trace in Grafana.

**Prerequisites:** this capstone builds on modules 03 (RustFS), 06 (Knative Serving)
and 08 (the portal) — have them green, or jump straight here with
`./scripts/catch-up.sh 8`.

## Why this matters

This is the capstone because it uses *everything you built today*, at once: GitOps
delivers it (02), RustFS stores it (03), Knative scales it from zero (06), the portal
fronts it (08), and the observability stack you enable on-demand right here — the
Victoria stack + OTel Collector — watches it end to end. The one new piece is
**Knative Eventing**: a Broker and Triggers — the open-source shape of S3 events → SQS →
Lambda. The uploader doesn't know the resizer exists; it emits a fact
(`dev.cloudbox.image.uploaded`, as a CloudEvent) and the Broker routes it to whoever
subscribed. That decoupling is the whole point of event-driven architecture, and today it
runs on your laptop, readable end to end.

## The task

1. Enable **two** catalog apps: `knative-eventing.yaml` (the event mesh — Broker/Trigger
   machinery in ns `knative-eventing`) and `picture-pipeline.yaml` (ns `pipeline`: a
   Broker, two cluster-local Knative Services — `uploader`, `resizer` — a Trigger, and a
   Job that creates the `images` bucket). Wait until
   `kubectl -n pipeline get broker,trigger,ksvc` is all Ready — then note the pod count
   in ns `pipeline`: with no traffic, both ksvcs sit at **zero**.
2. **The moment.** Two terminals:
   - `kubectl -n pipeline get pods -w`
   - open **http://localhost:30600/gallery** and upload any JPEG/PNG.

   Watch the uploader pod cold-start to receive the file, then — a beat later — the
   *resizer* appear from nowhere to handle the event. Nothing called it. Count the actors
   between your browser and that second pod.
3. **Find the results.** Both views of the same bucket:
   - the Gallery (refresh) shows the thumbnail + its metadata (dimensions, dominant color);
   - raw S3: `originals/`, `thumbs/`, and `meta/<key>.json` under bucket `images`
     (`aws s3 ls` against :30900 — module 03 muscle memory; hint 3 has the exact lines).
4. **Inspect the plumbing.** `kubectl -n pipeline get broker,trigger` — find what the
   Trigger filters on. Then read the resizer's logs and find the `ce-type`, `ce-source`,
   `ce-id` headers: a CloudEvent is just an HTTP POST with five headers. Where did your
   image bytes go, and what actually traveled through the Broker?
5. **The flourish.** Observability is an on-demand capability — enable the Victoria stack +
   OTel Collector from the catalog first (hint 5 has the files), then find the upload's trace
   in Grafana at **http://localhost:30030** → Explore → **VictoriaTraces** and see the chain —
   portal → uploader → broker → resizer — as one waterfall. Hint 5 if the Jaeger trace view is
   new to you.
6. Run `./verify.sh`.

## Hints

<details>
<summary>Hint 1: Enabling, and what "ready" looks like</summary>

In your Gitea clone:

```bash
cp gitops/catalog/knative-eventing.yaml gitops/apps/
cp gitops/catalog/picture-pipeline.yaml gitops/apps/
git add . && git commit -m "module 09: eventing + picture pipeline" && git push

kubectl -n knative-eventing get pods        # controller, webhook, broker ingress/filter, imc-*
kubectl -n pipeline get broker,trigger,ksvc # all Ready True
kubectl -n pipeline get job                 # create-images-bucket → Completions 1/1
```

Eventing's webhook takes a minute; the pipeline app retries until it's up (same dance as
module 06). Both can go in one push.
</details>

<details>
<summary>Hint 2: Upload works but no resizer pod appears</summary>

Follow the event, hop by hop:

1. Did the uploader get the file? `kubectl -n pipeline logs -l serving.knative.dev/service=uploader -c user-container --tail=20`
   — it logs the S3 key and the Broker's answer (expect `202 Accepted`).
2. Is the Trigger Ready and pointing at the resizer?
   `kubectl -n pipeline describe trigger resize-on-upload` — check the filter
   (`type: dev.cloudbox.image.uploaded`) and subscriber.
3. The Broker's delivery side lives in ns `knative-eventing`:
   `kubectl -n knative-eventing logs deploy/mt-broker-filter --tail=20` and
   `deploy/imc-dispatcher` — delivery errors (and retries) land there.
</details>

<details>
<summary>Hint 3: The S3 view of what happened</summary>

```bash
export AWS_ACCESS_KEY_ID=cloudbox AWS_SECRET_ACCESS_KEY=cloudbox123 AWS_REGION=us-east-1
aws --endpoint-url http://localhost:30900 s3 ls s3://images/originals/
aws --endpoint-url http://localhost:30900 s3 ls s3://images/thumbs/
aws --endpoint-url http://localhost:30900 s3 cp s3://images/meta/<key>.json - | cat
```

The metadata JSON (dimensions, dominant color) is the resizer's proof of work — the
gallery page renders exactly this file. No `aws` CLI? The in-cluster pattern from
module 03's hint 4 works verbatim (endpoint `http://rustfs-svc.rustfs.svc.cluster.local:9000`).
</details>

<details>
<summary>Hint 4: Prove the decoupling (what the explain-back is about)</summary>

Scale the resizer away and upload anyway. The Trigger keeps retrying delivery — watch
`kubectl -n knative-eventing logs deploy/imc-dispatcher -f` while the resizer is gone,
then let it come back and see the event land. Then ask the uncomfortable question: this
Broker is backed by an **in-memory** channel — what happens to waiting events if the
`imc-dispatcher` pod itself restarts? (That's why production brokers ride on Kafka —
and why this one deliberately doesn't; it's a lab.)
</details>

<details>
<summary>Hint 5: Enabling observability, then finding the trace in Grafana</summary>

The Victoria observability stack is an on-demand capability — enable it from the catalog
first (all five Applications go in one push):

```bash
cp gitops/catalog/victoria-metrics.yaml gitops/catalog/victoria-logs.yaml \
   gitops/catalog/victoria-traces.yaml gitops/catalog/grafana.yaml \
   gitops/catalog/otel-collector.yaml gitops/apps/
git add . && git commit -m "module 09: enable observability" && git push
kubectl -n observability get pods   # victoria-metrics/-logs/-traces, grafana, otel-collector (agents + gateway)
```

Then open Grafana at **http://localhost:30030** (NodePort — no port-forward needed) →
Explore → data source **VictoriaTraces** (the Jaeger datasource) → Search. Upload a fresh
image (traces are easiest to find seconds after you make them), then look for the
uploader/resizer service names and open the newest trace: one waterfall, portal to
thumbnail, with the Broker hop in the middle.
</details>

<details>
<summary>Full solution</summary>

```bash
WORKSHOP="$(git rev-parse --show-toplevel)"
cd ~/cloudbox-platform   # your Gitea clone

cp gitops/catalog/knative-eventing.yaml gitops/apps/
cp gitops/catalog/picture-pipeline.yaml gitops/apps/
git add . && git commit -m "module 09: eventing + picture pipeline" && git push

kubectl -n pipeline get broker,trigger,ksvc          # wait for Ready True across the board

kubectl -n pipeline get pods -w &                    # the watcher
# → http://localhost:30600/gallery — upload a photo, watch 0 → 1 → 0 twice
kill %1

export AWS_ACCESS_KEY_ID=cloudbox AWS_SECRET_ACCESS_KEY=cloudbox123 AWS_REGION=us-east-1
aws --endpoint-url http://localhost:30900 s3 ls s3://images/ --recursive   # originals/ thumbs/ meta/

kubectl -n pipeline logs -l serving.knative.dev/service=resizer -c user-container --tail=20   # ce-* headers

cd "$WORKSHOP/lab/09-capstone" && ./verify.sh
```

(No browser? `solve.sh` uploads a test PNG with plain `curl` through the portal — the
gallery form is just a multipart POST.)
</details>

## Check your work

```bash
./verify.sh
```

It checks: both apps Synced/Healthy; the eventing control plane and Broker data plane
are up; Broker `default` and Trigger `resize-on-upload` are Ready; both ksvcs are Ready;
bucket `images` exists; and — if anything has been uploaded — that every batch of
originals has produced at least one matching thumbnail. The upload itself needs a human
(or `solve.sh`): the machinery is verifiable, the *moment* is yours.

## Explain-back

Tell your neighbor: why does the uploader POST an event to a Broker instead of just
calling the resizer's URL — what breaks, and what becomes possible, under each design?
(Think: adding a third consumer; deploying a broken resizer.) And when the resizer is
down, *where exactly* does the event wait — and what would take that waiting event to
production grade?

## Going deeper

- **Second consumer, zero coupling.** Add another Trigger on the same
  `dev.cloudbox.image.uploaded` type pointing at a new ksvc (start from module 06's
  `hello` — its logs will show the CloudEvent POSTs). Note what you did *not* have to
  change: the uploader.
- **Policy at the edge.** Make the uploader reject files over 5 MB with a `413`
  (`apps/uploader/main.go` — it's a few lines around the multipart read), rebuild with
  module 07's in-cluster pipeline, roll it out via git.
- **Sepia.** Fork `apps/resizer` into a sepia-filter service writing `sepia/<key>`,
  subscribe it with its own Trigger — a second opinion on every upload, built entirely
  from parts you own.
- You built S3-events → queue → function on a laptop. Sketch which managed products
  this replaces on your cloud bill, and what you'd genuinely still pay for.
