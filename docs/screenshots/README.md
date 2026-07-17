# Console screenshots

Rendered shots of the Cloudbox Console, for slides and the README. They render
the **real** templates + `style.css` with representative mock data (so they stay
faithful to the shipped UI), then screenshot the HTML with a headless browser.

Every page has a light and a `-dark` variant (the console is theme-aware via
`prefers-color-scheme`); only the light names are listed below.

| File | What |
|---|---|
| `console-component-monitoring.png` | A component's **Monitoring** detail page — CPU + memory sparklines and a live log tail, sourced from the OTel stack (#56). |
| `console-component-monitoring-mobile.png` | The same page at phone width — the rail collapses to a sticky bar (logo + ☰) so content is immediately visible. |
| `console-mobile-nav-open.png` | Phone width with the ☰ menu tapped open — the full nav revealed (CSS-only, no JS). |
| `console-component-locked.png` | The Monitoring page when observability isn't enabled yet — degrade-in-place hint. |
| `console-components.png` | The Components page — per-namespace health, each linking into its Monitoring detail. |
| `console-applications.png` | The **Applications** page — the golden path (PRD-0003) as a console action: deploy an app + its Postgres database + S3 bucket from one `Application` XR, with per-row Ready/URL/Delete (#28). |
| `console-new-application.png` | The **New application** modal — the fullest form in the console: source (image or repo), min/max scale, env vars, and the database/bucket dependency toggles (#28). |
| `console-deploy-from-source.png` | The **New application** modal with **Source → Build from a repo** — the app-team golden path: point at an in-cluster Gitea repo and the platform builds it (Argo + BuildKit → Zot) and deploys it as an Application (PRD-0012). |
| `console-services.png` | The **Functions** page — the whole function lifecycle in the **Services** nav section: request-rate + avg-latency sparklines and scale-from-zero per Knative Service (#56), an **Invoke** button that wakes one server-side, **Delete** for console-built functions, and a **New function** button that opens the build-and-deploy modal (#58). |
| `console-new-function.png` | The **New function** modal (CSS-only, no JS) — name, source, optional env vars, and a keep-warm toggle; builds source in-cluster (Argo + BuildKit) and deploys it as a scale-to-zero Knative Service (#58). |
| `console-database-monitoring.png` | A database's detail page — CNPG connections, cache-hit ratio and size (#56), plus a **Resize** control (change the T-shirt size → Crossplane re-composes, #27) and the delete danger zone. |
| `console-builds-monitoring.png` | The Builds page — BuildKit's CPU/memory in the builds namespace, above the live Argo Workflows runs (#56). |
| `console-streams-monitoring.png` | The Streams page — JetStream messages/bytes + connections from the NATS exporter sidecar (#56). |
| `console-buckets-monitoring.png` | The Buckets page — RustFS pod CPU/memory (generic fallback; RustFS has no Prometheus endpoint) (#56), plus full S3 CRUD: create a bucket, upload and delete objects, delete a bucket (#26). |

## Regenerating

Two steps — a Go test writes standalone HTML (with `style.css` inlined), then a
Playwright script shoots it. The generator lives in
`apps/portal/internal/web/component_detail_test.go` (`TestGenerateScreenshots`),
so adding a page to the shot list is a code change next to the templates.

```sh
# 1. render the pages to self-contained HTML
cd apps/portal
SCREENSHOTS=1 SCREENSHOTS_DIR=/tmp/shots go test -run Screenshots ./internal/web/

# 2. screenshot them — light + dark desktop for every page, plus -mobile /
#    -mobile-nav shots for the monitoring page
npx playwright install chromium          # one-time
node ../../scripts/screenshots.mjs /tmp/shots /tmp/shots

# 3. copy the ones you want into this directory
cp /tmp/shots/component-detail-monitoring.png docs/screenshots/console-component-monitoring.png
# …etc
```

Shots are 2× device-scale for crisp slides.
