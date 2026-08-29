# Door 1 — App dev: build something real on the platform

**You came for:** what it feels like to be a product team on a platform —
ship an app, get its dependencies by declaring them, never file a ticket.

**Prerequisites:** module 04 (self-service). Richer with 06 (Knative),
07 (in-cluster CI) and 09 (the pipeline). `./scripts/catch-up.sh 9` gets you
everything.

## The mission

Bruktby's platform team (you, until now) hands the keys to Bruktby's product
team (also you, starting now). Build and ship a service of your own on the
platform, using only what the platform offers: the golden path, the event mesh,
the in-cluster CI.

## Warm-up (~15 min, guaranteed win)

Ship an app with **one YAML file** — the golden-path `Application` XR
(enable `catalog/application-xr.yaml` if you haven't):

```yaml
apiVersion: platform.cloudbox.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: default
spec:
  image: ghcr.io/knative/helloworld-go:latest   # pre-pulled; swap for your own later
  replicas: { min: 0, max: 2 }
```

Push it through Gitea, then look at what one manifest bought you: a
scale-from-zero Knative Service with a URL
(`http://my-app-default.kn.cloudbox.k8s.test`), its own Postgres
(a `WorkshopDatabase` XR underneath — composition-of-compositions), and an S3
bucket `my-app-data`. That's a nais.yaml-shaped experience you built yourself in
module 04. Read `gitops/components/application-xr/composition.yaml` and find
where each of the three came from.

## The build — pick your altitude

**Level 1 — a second consumer on the event mesh.** The picture pipeline's
uploader doesn't know the resizer exists; it publishes
`dev.cloudbox.image.uploaded` to a Broker. So subscribe something *else* to the
same event: an EXIF extractor, a content moderator that flags suspiciously
perfect stock photos, an audit logger. One new Knative Service + one new
`Trigger` in ns `pipeline` — the uploader is untouched, which is the entire
argument for event-driven design. Crib the resizer: its full source is in
`apps/resizer/`, and a CloudEvent is just an HTTP POST with five `ce-*` headers.

**Level 2 — build it in-cluster.** Don't `docker build` — you own a CI system.
Put your service's source in your Gitea, build it with the module 07 pipeline
(BuildKit → your Zot registry), and deploy `localhost:30500/<your-image>` via
GitOps. The loop closes entirely inside your laptop.

**Level 3 — Bruktby's listings service.** The pipeline stores photos, but
Bruktby sells *things*: an API that creates a listing (title, price, photo key)
in Postgres via an `Application` XR, publishes `dev.cloudbox.listing.created`,
and a worker that consumes it off **NATS JetStream** (`catalog/nats.yaml`) so a
crashed worker replays instead of losing the sale. Durable vs in-memory is the
module-10-adjacent punchline — kill your worker mid-event and watch the replay.

## You know it works when…

- Warm-up: `kubectl get application my-app` is Ready and the URL serves.
- Level 1: upload a photo in the Gallery → your service's logs show the event —
  *and the thumbnail still appears* (you broke nothing).
- Level 2: `crane ls localhost:30500/<repo> --insecure` lists your tag and the
  running pod's image is your Zot URL.
- Level 3: `nats stream info` shows your consumer's ack floor advancing.

## Known traps

- **`spec.env` on the Application XR is accepted but NOT wired (v1).** Documented
  limitation, not your bug — config via env means going one layer down to a
  plain Knative Service, or extending the composition (that's door 2 energy).
- **Go base images**: in-cluster builds must `FROM` your own registries
  (the image mirror — `localhost:5001` on docker, which holds every registry's images;
  on tbx the host reaches docker.io at `172.30.<n>.1:5055`, ghcr.io `:5056`, quay.io `:5057`,
  registry.k8s.io `:5058`, and nothing else host-side — or Zot :30500) — Docker Hub is rate-limited at the venue. The
  mirror's image list is `scripts/images.txt`; if the base you want isn't
  there, build `FROM` busybox/static, or vendor the base at home.
- **Cluster-local ksvc URLs** (pipeline services) don't resolve from your
  browser — that's deliberate; test with `kubectl run curl-test`.
- **`kubectl create -f workflow-run.yaml`**, not `apply` — it uses
  `generateName`.
- The builds namespace is PSA-privileged for rootless BuildKit; your app
  namespaces are not, and shouldn't be.

## At home

Wire your Level-3 listings API into the Console (its source is `apps/`), or give
the Application XR the `spec.env` wiring it's missing and PR it — the
composition is ~200 lines and the repo takes contributions.
