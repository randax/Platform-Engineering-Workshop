# Workshop applications

The three bespoke apps the workshop platform runs. They are written to be
**read** — each one makes a point about how little code a platform feature
actually needs:

| App | What it is | The point it makes |
|---|---|---|
| [`portal/`](portal/) | **Cloudbox Console** — the hands-on developer portal (module 08). Server-rendered HTML + htmx over the Kubernetes API, RustFS, and Prometheus. Pages: Overview, Components (statuspage + marketplace), Workshop progress, Activity (cluster events), Billing (the kr 0,00 invoice), Databases (+ per-database detail page), Services (with request-rate sparklines), Gallery. | A portal is just REST calls: ~50 lines of `net/http` replace client-go; a database is one POST of a Crossplane XR; a metrics chart is one Prometheus query and some SVG. |
| [`uploader/`](uploader/) | Capstone pipeline, front half: accepts an image upload, stores it in the `images` bucket, announces it as a CloudEvent. | A binary-mode CloudEvent is an HTTP POST with five `ce-*` headers — no SDK. |
| [`resizer/`](resizer/) | Capstone pipeline, back half: receives the CloudEvent from the broker, writes a 320px thumbnail to `thumbs/` and an analysis JSON to `meta/`. | Event-driven autoscaling: watch its pod appear from zero when an upload lands. |

Images (multi-arch, amd64 + arm64) are published to GHCR by
[`build-images.yaml`](../.github/workflows/build-images.yaml) — **run it once
before the workshop** (push an `apps-v*` tag to publish the pinned version;
see the PENDING note in `scripts/images.txt`) — and pre-pulled by
`cloudbox-init.sh`:

```
ghcr.io/randax/cloudbox-portal:v0.1.0
ghcr.io/randax/cloudbox-uploader:v0.1.0
ghcr.io/randax/cloudbox-resizer:v0.1.0
```

> **You do not need Go for the workshop.** The platform deploys these prebuilt
> images; the source is here for reading, tinkering after the workshop, and as
> build fodder for the in-cluster CI module.

## Architecture (portal)

```
apps/portal/
  main.go            wiring only: config → clients → page registry → serve
  config.go          every env var, parsed once, defaults on one screen
  telemetry.go       OTLP traces + metrics setup
  internal/kube/     the plain-HTTP Kubernetes client + typed resources,
                     workshop progress rules, workload/node accounting
  internal/store/    the S3 gallery store (RustFS)
  internal/metrics/  Prometheus range queries + hand-rolled SVG sparklines
  internal/web/      one file per page + templates/ + static/ (go:embed)
```

**Adding a page** (the extension point — also lab 08's going-deeper
exercise): the sidebar and the routes are both built from the page registry
in `internal/web/registry.go`, so:

1. Copy any page file in `internal/web/` (say `billing.go`) to `mypage.go`.
2. Change the `register(Page{...})` call: pick a `Weight` (sidebar position),
   section, title, and path; point `Handler` at your handler.
3. Add a template in `internal/web/templates/` and render it. Done — no
   router edits, no layout edits, no central list.

All configuration enters through `config.go` — see the
[environment variables](#environment-variables) table below.

The uploader and resizer deliberately do NOT get this structure: a service
that fits in one readable file should stay one file.

## Running locally

Each app is its own Go module (Go 1.24). Dependencies are deliberately
minimal: `minio-go` for S3, `x/image` for scaling, stdlib for everything else.

```bash
# Portal — point it at any cluster via kubectl proxy (no token needed):
kubectl proxy &
cd portal && KUBE_API_URL=http://127.0.0.1:8001 go run .
# open http://localhost:8080

# Uploader / resizer — need an S3 endpoint:
cd uploader && S3_ENDPOINT=localhost:30900 go run .
cd resizer  && S3_ENDPOINT=localhost:30900 go run .
```

### Environment variables

Common to all three (defaults match the in-cluster RustFS):

| Var | Default | |
|---|---|---|
| `S3_ENDPOINT` | `rustfs-svc.rustfs.svc.cluster.local:9000` | S3 API endpoint |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | `cloudbox` / `cloudbox123` | credentials |
| `S3_BUCKET` | `images` | pipeline bucket |
| `PORT` | `8080` | listen port (Knative injects this) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://lgtm.observability.svc.cluster.local:4318` | where traces AND metrics are pushed (OTLP/HTTP) |
| `OTEL_SERVICE_NAME` | `cloudbox-portal` / `-uploader` / `-resizer` | service name shown in Grafana |

Portal only:

| Var | Default | |
|---|---|---|
| `S3_PUBLIC_ENDPOINT` | `localhost:30900` | endpoint presigned URLs are signed for — must be the address **your browser** can reach (the RustFS NodePort) |
| `PROM_URL` | `http://lgtm.observability.svc.cluster.local:9090` | Prometheus API for the sparklines |
| `GRAFANA_URL` | `http://localhost:30030` | browser-facing Grafana for the deep links (NodePort) |
| `UPLOADER_URL` | `http://uploader.pipeline.svc.cluster.local` | where upload POSTs are forwarded |
| `KUBE_API_URL` / `KUBE_TOKEN` | *(unset)* | override in-cluster API discovery for local dev |

Uploader only:

| Var | Default | |
|---|---|---|
| `BROKER_URL` | `http://broker-ingress.knative-eventing.svc.cluster.local/pipeline/default` | Knative broker ingress the CloudEvents are POSTed to |

## Tracing and metrics

All three apps push OpenTelemetry traces AND metrics (OTLP/HTTP) to the
platform's `grafana/otel-lgtm` pod and propagate W3C `traceparent` headers on
every hop —
including through the CloudEvent POST, which Knative's broker forwards to the
resizer. The payoff: one upload from the portal shows up in Grafana
(`kubectl -n observability port-forward svc/lgtm 3000`, then Explore → Tempo)
as a **single distributed trace**,
`cloudbox-portal → cloudbox-uploader → cloudbox-resizer`, with the S3 calls
and the resize step as child spans.

Each app's `telemetry.go` is identical apart from the service name. If the
observability stack isn't running, the apps log one warning and keep working —
data is dropped in the background, never blocking a request.

Metrics: otelhttp emits request count/duration per service for free once a
global meter provider exists; on top of that each app keeps one counter —
`cloudbox.pages.rendered` (portal), `cloudbox.uploads.accepted` (uploader),
`cloudbox.images.processed` (resizer). Prometheus normalizes OTLP names on
ingest, so query them as `cloudbox_pages_rendered_total` etc., with the OTel
service name in the `job` label. The portal's sparklines are exactly that:
`sum(rate(http_server_duration_milliseconds_count{job="cloudbox-uploader"}[5m]))`
rendered as a hand-rolled SVG polyline.

## Tests

```bash
cd portal   && go vet ./... && go test ./...
cd uploader && go vet ./... && go test ./...
cd resizer  && go vet ./... && go test ./...
```

## How the images are built

- **GitHub Actions** ([`.github/workflows/build-images.yaml`](../.github/workflows/build-images.yaml)):
  vet + test on every PR touching `apps/**`; buildx multi-arch builds pushed
  to GHCR on pushes to `main` (SHA tag only) and on `apps-v*` tags (SHA tag
  plus the pinned version tag — the only way the pinned tag moves).
- **In-cluster CI (module 07):** the same Dockerfiles build with the rootless
  BuildKit + Zot registry running inside your cluster — point the module 07
  workflow at any of these directories and push the result to
  `zot.zot.svc.cluster.local:5000`, then flip the image in the gitops repo.
  Nothing about these builds requires GitHub: that is the point of that module.

All three Dockerfiles are the same shape: `golang:1.24-alpine` build stage,
static `CGO_ENABLED=0` binary, `FROM scratch` final image, non-root UID.

## Vendored assets

The portal embeds [htmx](https://htmx.org) v2.0.4
(`portal/static/htmx.min.js`), © Big Sky Software, licensed under the
Zero-Clause BSD license (0BSD) — vendored so the portal serves everything
itself (offline rule).
