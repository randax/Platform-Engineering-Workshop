# Workshop applications

The three bespoke apps the workshop platform runs. They are written to be
**read** — each one makes a point about how little code a platform feature
actually needs:

| App | What it is | The point it makes |
|---|---|---|
| [`portal/`](portal/) | **Cloudbox Console** — the hands-on developer portal (module 08). Server-rendered HTML + htmx over the Kubernetes API, RustFS, and Prometheus. Pages, grouped in the nav: **Platform** — Overview, Components (statuspage + marketplace), Access, Workshop progress, Activity (cluster events), Billing (the kr 0,00 invoice); **Services** — Applications, Databases, Buckets, Functions, Streams, Builds (several with per-resource detail pages carrying diagnostics + monitoring); **Capstone** — Gallery. | A portal is just REST calls: ~50 lines of `net/http` replace client-go; a database is one POST of a Crossplane XR; a metrics chart is one Prometheus query and some SVG. |
| [`uploader/`](uploader/) | Capstone pipeline, front half: accepts an image upload, stores it in the `images` bucket, announces it as a CloudEvent. | A binary-mode CloudEvent is an HTTP POST with five `ce-*` headers — no SDK. |
| [`resizer/`](resizer/) | Capstone pipeline, back half: receives the CloudEvent from the broker, writes a 320px thumbnail to `thumbs/` and an analysis JSON to `meta/`. | Event-driven autoscaling: watch its pod appear from zero when an upload lands. |

Images (multi-arch, amd64 + arm64) are published to GHCR by
[`build-images.yaml`](../.github/workflows/build-images.yaml), driven by
release-please (see [Releasing the images](#releasing-the-images)), and
pre-pulled by `cloudbox-init.sh`:

<!-- x-release-please-start-version -->
```
ghcr.io/randax/cloudbox-portal:v0.4.0
ghcr.io/randax/cloudbox-uploader:v0.4.0
ghcr.io/randax/cloudbox-resizer:v0.4.0
```
<!-- x-release-please-end-version -->

A fourth image, `ghcr.io/randax/cloudbox-grafana`, is built from
[`grafana/`](grafana/) by the same workflow (stock Grafana plus the native
VictoriaMetrics datasource plugins). It joined the build matrix after
`apps-v0.1.0` was tagged, so it has no published version yet — issue #7.

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

Each app is its own Go module (toolchain version pinned by the `go`
directive in each app's `go.mod`). Dependencies are deliberately
minimal: `minio-go` for S3, `x/image` for scaling, stdlib for everything else.

```bash
# Portal — point it at any cluster via kubectl proxy (no token needed):
# LAB_MODE=1 supplies the workshop S3 default so local dev doesn't fail-close.
kubectl proxy &
cd portal && LAB_MODE=1 KUBE_API_URL=http://127.0.0.1:8001 go run .
# open http://localhost:8080

# Uploader / resizer — need an S3 endpoint:
cd uploader && S3_ENDPOINT=s3.cloudbox.k8s.test go run .
cd resizer  && S3_ENDPOINT=s3.cloudbox.k8s.test go run .
```

### Environment variables

Common to all three (defaults match the in-cluster RustFS):

| Var | Default | |
|---|---|---|
| `S3_ENDPOINT` | `rustfs-svc.rustfs.svc.cluster.local:9000` | S3 API endpoint |
| `S3_ACCESS_KEY` | `cloudbox` | access key (a username, not a secret) |
| `S3_SECRET_KEY` | `cloudbox123` (uploader/resizer only) | secret key. The **portal has no default** — it fails closed at startup unless the Secret is set, or `LAB_MODE=1` selects the workshop default (see Portal-only below). Uploader/resizer still fall back to it. |
| `S3_BUCKET` | `images` | pipeline bucket |
| `PORT` | `8080` | listen port (Knative injects this) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector.observability.svc.cluster.local:4318` | where traces AND metrics are pushed (OTLP/HTTP), to the OTel Collector gateway |
| `OTEL_SERVICE_NAME` | `cloudbox-portal` / `-uploader` / `-resizer` | service name shown in Grafana |

Portal only:

| Var | Default | |
|---|---|---|
| `S3_PUBLIC_ENDPOINT` | `s3.cloudbox.k8s.test` | endpoint presigned URLs are signed for — must be the address **your browser** can reach |
| `PROM_URL` | `http://victoria-metrics.observability.svc.cluster.local:8428` | VictoriaMetrics (Prometheus query API) for the sparklines |
| `VLOGS_URL` | `http://victoria-logs.observability.svc.cluster.local:9428` | VictoriaLogs query API for the per-component log tail |
| `GRAFANA_URL` | `http://grafana.cloudbox.k8s.test` | browser-facing Victoria-stack Grafana for the deep links |
| `NATS_MONITOR_URL` | `http://nats.nats.svc.cluster.local:8222` | NATS monitoring endpoint for the JetStream/Streams browser |
| `ZOT_URL` | `http://zot.zot.svc.cluster.local:5000` | cluster-internal Zot registry, read by the Builds page |
| `UPLOADER_URL` | `http://uploader.pipeline.svc.cluster.local` | where upload POSTs are forwarded |
| `KUBE_API_URL` / `KUBE_TOKEN` | *(unset)* | override in-cluster API discovery for local dev |
| `LAB_MODE` | *(unset)* | set to `1` to let a missing `S3_SECRET_KEY` fall back to the workshop default; otherwise the portal exits at startup rather than run on a public password |

Uploader only:

| Var | Default | |
|---|---|---|
| `BROKER_URL` | `http://broker-ingress.knative-eventing.svc.cluster.local/pipeline/default` | Knative broker ingress the CloudEvents are POSTed to |

## Tracing and metrics

All three apps push OpenTelemetry traces AND metrics (OTLP/HTTP) to the
platform's **OTel Collector** gateway
(`otel-collector.observability.svc.cluster.local:4318`), which fans traces out
to VictoriaTraces and metrics to VictoriaMetrics — and they propagate W3C
`traceparent` headers on every hop, including through the CloudEvent POST, which
Knative's broker forwards to the resizer. The payoff: once the on-demand Victoria
observability stack is enabled (module 09), one upload from the portal shows up
in Grafana at **http://grafana.cloudbox.k8s.test** → Explore → **VictoriaTraces** (the
Jaeger datasource) as a **single distributed trace**,
`cloudbox-portal → cloudbox-uploader → cloudbox-resizer`, with the S3 calls
and the resize step as child spans.

Each app's `telemetry.go` is identical apart from the service name. If the
observability stack isn't running (it's an on-demand capability), the apps log
one warning and keep working — data is dropped in the background, never blocking
a request.

Metrics: otelhttp emits request count/duration per service for free once a
global meter provider exists; on top of that each app keeps one counter —
`cloudbox.pages.rendered` (portal), `cloudbox.uploads.accepted` (uploader),
`cloudbox.images.processed` (resizer). VictoriaMetrics normalizes OTLP names on
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

The portal's tests are **hermetic** — no cluster, no network. Template render
tests execute every page with representative data, so a typo in a template or a
renamed struct field fails `go test`, not a live page. The kube client, NATS,
and registry HTTP layers are each driven against an `httptest` server standing
in for the real backend. And the handlers run end to end through the
`newTestServer` seam: a real `*Server` whose kube client points at an `httptest`
stand-in for the Kubernetes API, so the full request → fetch → k8s call → render
path (RBAC-gated writes, project-cookie scoping, fragment-vs-error responses) is
exercised in `go test` milliseconds. The 20-minute CI rehearsal stays what it's
good at: a coarse end-to-end convergence check, not the per-feature correctness
net.

## How the images are built

- **GitHub Actions** ([`.github/workflows/build-images.yaml`](../.github/workflows/build-images.yaml)):
  vet + test on every PR touching `apps/**`; buildx multi-arch builds pushed
  to GHCR on pushes to `main` (SHA tag only) and, for a release, the pinned
  `:v<version>` tag as well — see [Releasing the images](#releasing-the-images).
- **In-cluster CI (module 07):** the same Dockerfiles build with the rootless
  BuildKit + Zot registry running inside your cluster — point the module 07
  workflow at any of these directories and push the result to
  `zot.zot.svc.cluster.local:5000`, then flip the image in the gitops repo.
  Nothing about these builds requires GitHub: that is the point of that module.

All three Dockerfiles are the same shape: pinned `golang` alpine build stage
(same Go minor as the modules' `go.mod` — the CI guard enforces this),
static `CGO_ENABLED=0` binary, `FROM scratch` final image, non-root UID.

## Releasing the images

The four images are versioned as one bundle and released by release-please.
Nothing here is edited by hand — including the pinned tags:

1. Change something under `apps/` and merge it to `main` with a conventional
   commit (`fix:` → patch, `feat:` → minor, `!`/`BREAKING CHANGE` → major).
2. [`release-please.yaml`](../.github/workflows/release-please.yaml) keeps a
   **release PR** open with the next version and the generated
   `apps/CHANGELOG.md`. Nothing is published until a human merges it.
3. That PR also rewrites **every pinned `ghcr.io/randax/cloudbox-*:v…` ref in
   the repo** — the gitops components, the lab example, the pre-pull list, this
   file — via the `extra-files` list in
   [`release-please-config.json`](../release-please-config.json). The
   `x-release-please` start/end block comments around those refs are what makes
   that work; do not remove them. (Never write those markers out verbatim in a
   file that is itself an extra-file — a stray "start" with no matching "end"
   puts the rest of the file in the block and rewrites unrelated versions.)
4. Merging the PR creates the `apps-v<version>` tag and calls
   `build-images.yaml`, which pushes the multi-arch `:v<version>` images.
5. **The one manual step:** a brand-new GHCR package is created *private*,
   and package visibility has no REST endpoint — CI cannot flip it.
   After the first publish of a new image, open
   `https://github.com/users/randax/packages/container/<image>/settings` and
   set the visibility to public. Existing packages keep their setting, so this
   is once per image, not once per release. Until then
   [`images-gate.yaml`](../.github/workflows/images-gate.yaml) warns instead of
   failing for that ref.

Escape hatches, when release-please is not the right tool: push an `apps-v*`
tag by hand, or run `gh workflow run build-images.yaml -f version=<x.y.z>`.
Neither updates the pinned refs — only the release PR does that.

## Vendored assets

The portal embeds [htmx](https://htmx.org) v2.0.4
(`portal/static/htmx.min.js`), © Big Sky Software, licensed under the
Zero-Clause BSD license (0BSD) — vendored so the portal serves everything
itself (offline rule).
