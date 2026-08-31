# Module 09 (capstone): the picture pipeline, everything wired together

## The goal

Your platform runs an event-driven picture pipeline: you drop a photo into the Cloudbox
Console's Gallery, and a resizer service *that is not running* wakes from zero, makes a
thumbnail and a metadata file, and goes back to sleep. You prove it three ways: pods
appearing in a `-w` watch, the thumbnail landing in the gallery and in S3, and, for the
flourish, the whole chain as a single trace in Grafana.

<p align="center">
  <img src="../../docs/screenshots/console-component-monitoring-dark.png" alt="Cloudbox Console: a component's Monitoring page: CPU/memory sparklines and a live log tail from the OTel stack" width="80%" />
</p>

<p align="center"><em>Per-component metrics and logs in the Console come from the same OTel
telemetry that renders your upload as one end-to-end trace in Grafana.</em></p>

**Prerequisites:** modules 03 (RustFS), 06 (Knative Serving) and 08 (the portal). Have
them green, or jump straight here with `mise run catch-up 8`.

## Why this matters

This uses everything you built today at once: GitOps delivers it, RustFS stores it,
Knative scales it from zero, the portal fronts it. The one new piece is Knative
Eventing, a Broker and Triggers, the open-source shape of S3 events → SQS → Lambda: the
uploader doesn't know the resizer exists, it emits a CloudEvent
(`dev.cloudbox.image.uploaded`) and the Broker routes it to whoever subscribed.

## The task

1. Enable two catalog apps and push: `knative-eventing.yaml` (Broker/Trigger machinery,
   ns `knative-eventing`) and `picture-pipeline.yaml` (ns `pipeline`: a Broker, two
   cluster-local ksvcs `uploader` and `resizer`, a Trigger, and a Job that creates the
   `images` bucket). Wait for `kubectl -n pipeline get broker,trigger,ksvc` all Ready.
   With no traffic, both ksvcs sit at zero pods.
2. **The moment.** Two terminals:
   - `kubectl -n pipeline get pods -w`
   - open **http://portal.cloudbox.k8s.test/gallery** and upload any JPEG/PNG.

   The uploader cold-starts to receive the file, then the resizer appears from nowhere
   to handle the event. Nothing called it. The first upload is the slow one (both
   services boot from zero); the gallery says "waiting for the resizer…" until the
   thumbnail lands.
3. **Find the results.** The Gallery (refresh) shows the thumbnail and its metadata;
   raw S3 has `originals/`, `thumbs/`, and `meta/<key>.json` under bucket `images`
   (hint 3 has the `s5cmd` lines).
4. **Inspect the plumbing.** `kubectl -n pipeline get broker,trigger`: what does the
   Trigger filter on? Then find the `ce-type`, `ce-source`, `ce-id` headers in the
   resizer's logs. A CloudEvent is just an HTTP POST with five headers; what actually
   traveled through the Broker?
5. **The flourish.** Enable the Victoria stack + OTel Collector from the catalog
   (hint 5), then find the upload's trace in Grafana at
   **http://grafana.cloudbox.k8s.test** → Explore → VictoriaTraces: portal → uploader →
   broker → resizer as one waterfall.
6. Run `./verify.sh`.

## Check your work

```bash
./verify.sh
```

It grades the machinery; the upload itself needs a human (or `solve.sh`). The *moment*
is yours.

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

Eventing's webhook takes a minute; the pipeline app retries until it's up (same dance
as module 06). Both can go in one push.
</details>

<details>
<summary>Hint 2: Upload works but no resizer pod appears</summary>

Follow the event, hop by hop:

1. Did the uploader get the file? `kubectl -n pipeline logs -l serving.knative.dev/service=uploader -c user-container --tail=20`.
   It logs the S3 key and the Broker's answer (expect `202 Accepted`).
2. Is the Trigger Ready and pointing at the resizer?
   `kubectl -n pipeline describe trigger resize-on-upload`: check the filter
   (`type: dev.cloudbox.image.uploaded`) and subscriber. `NotReady` with reason
   `BrokerNotConfigured` means it reconciled before the broker was Ready and latched;
   once everything is Ready, nudge it:
   `kubectl -n pipeline annotate trigger/resize-on-upload cloudbox.io/rereconcile="$(date +%s)" --overwrite`
   (exactly what `solve.sh` does).
3. Delivery errors and retries land in ns `knative-eventing`:
   `kubectl -n knative-eventing logs deploy/mt-broker-filter --tail=20` and
   `deploy/imc-dispatcher`.
</details>

<details>
<summary>Hint 3: The S3 view of what happened</summary>

```bash
export AWS_ACCESS_KEY_ID=cloudbox AWS_SECRET_ACCESS_KEY=cloudbox123 AWS_REGION=eu-north-1
s5cmd --endpoint-url http://s3.cloudbox.k8s.test ls s3://images/originals/
s5cmd --endpoint-url http://s3.cloudbox.k8s.test ls s3://images/thumbs/
s5cmd --endpoint-url http://s3.cloudbox.k8s.test cat s3://images/meta/<key>.json
```

The metadata JSON is the resizer's proof of work; the gallery renders exactly this
file. No S3 client? Module 03 hint 4's in-cluster pattern works verbatim (endpoint
`http://rustfs-svc.rustfs.svc.cluster.local:9000`).

Two `s5cmd` details `verify.sh` depends on: `ls --show-fullpath` is what prints whole
keys, and `ls` on an empty prefix exits 1 with `no object found`, which here means
"the resizer hasn't landed yet", not "broken". The apps themselves use `minio-go`:
s5cmd in your terminal, minio-go in the pipeline, one S3 API, and RustFS cannot
tell them apart.
</details>

<details>
<summary>Hint 4: Prove the decoupling (what the explain-back is about)</summary>

The uploader never waits for the resizer: it logs the Broker's `202 Accepted` and is
done, and the resizer's cold start happens after that (both visible in your `-w`
watch). Now the uncomfortable question: this Broker is backed by an **in-memory**
channel, and delivery is at-most-once. Restart the middleman
(`kubectl -n knative-eventing rollout restart deploy/imc-dispatcher`) and upload
during the roll: an accepted event can vanish for good, with no error anywhere, and
the fix is what you'd do in the gallery anyway, upload again. That's why production
brokers ride on Kafka, and why this one deliberately doesn't; it's a lab.
</details>

<details>
<summary>Hint 5: Enabling observability, then finding the trace in Grafana</summary>

All five Applications go in one push:

```bash
cp gitops/catalog/victoria-metrics.yaml gitops/catalog/victoria-logs.yaml \
   gitops/catalog/victoria-traces.yaml gitops/catalog/grafana.yaml \
   gitops/catalog/otel-collector.yaml gitops/apps/
git add . && git commit -m "module 09: enable observability" && git push
kubectl -n observability get pods   # victoria-metrics/-logs/-traces, grafana, otel-collector
```

Then Grafana at **http://grafana.cloudbox.k8s.test** → Explore → data source
**VictoriaTraces** (the Jaeger datasource) → Search. Upload a fresh image (traces are
easiest to find seconds after you make them) and open the newest uploader/resizer
trace: one waterfall, portal to thumbnail, with the Broker hop in the middle.
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
# open http://portal.cloudbox.k8s.test/gallery, upload a photo, watch 0 → 1 → 0 twice
kill %1

export AWS_ACCESS_KEY_ID=cloudbox AWS_SECRET_ACCESS_KEY=cloudbox123 AWS_REGION=eu-north-1
s5cmd --endpoint-url http://s3.cloudbox.k8s.test ls --show-fullpath "s3://images/*"   # originals/ thumbs/ meta/

kubectl -n pipeline logs -l serving.knative.dev/service=resizer -c user-container --tail=20   # ce-* headers

cd "$WORKSHOP/lab/09-capstone" && ./verify.sh
```

(No browser? `solve.sh` uploads a test PNG with plain `curl` through the portal. The
gallery form is just a multipart POST.)
</details>

## Explain-back

Why does the uploader POST an event to a Broker instead of calling the resizer's URL?
And when the resizer is down, where exactly does the event wait?

## Going deeper

- Second consumer, zero coupling: add another Trigger on the same event type pointing at a new ksvc (module 06's `hello` will log the CloudEvent POSTs; or fork `apps/resizer` into a sepia filter writing `sepia/<key>`). Note what you did not change: the uploader.
- Policy at the edge: make the uploader reject files over 5 MB with a `413` (`apps/uploader/main.go`), rebuild with module 07's pipeline, roll it out via git.
- You built S3-events → queue → function on a laptop. Which managed products does this replace on your cloud bill, and what would you genuinely still pay for?
