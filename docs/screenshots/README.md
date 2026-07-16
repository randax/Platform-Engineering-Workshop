# Console screenshots

Rendered shots of the Cloudbox Console, for slides and the README. They render
the **real** templates + `style.css` with representative mock data (so they stay
faithful to the shipped UI), then screenshot the HTML with a headless browser.

| File | What |
|---|---|
| `console-component-monitoring.png` | A component's **Monitoring** detail page — CPU + memory sparklines and a live log tail, sourced from the OTel stack (#56). |
| `console-component-monitoring-mobile.png` | The same page at phone width — the rail collapses to a wrapping top bar. |
| `console-component-locked.png` | The Monitoring page when observability isn't enabled yet — degrade-in-place hint. |
| `console-components.png` | The Components page — per-namespace health, each linking into its Monitoring detail. |

## Regenerating

Two steps — a Go test writes standalone HTML (with `style.css` inlined), then a
Playwright script shoots it. The generator lives in
`apps/portal/internal/web/component_detail_test.go` (`TestGenerateScreenshots`),
so adding a page to the shot list is a code change next to the templates.

```sh
# 1. render the pages to self-contained HTML
cd apps/portal
SCREENSHOTS=1 SCREENSHOTS_DIR=/tmp/shots go test -run Screenshots ./internal/web/

# 2. screenshot them (desktop + a -mobile shot for the monitoring page)
npx playwright install chromium          # one-time
node ../../scripts/screenshots.mjs /tmp/shots /tmp/shots

# 3. copy the ones you want into this directory
cp /tmp/shots/component-detail-monitoring.png docs/screenshots/console-component-monitoring.png
# …etc
```

Shots are 2× device-scale for crisp slides.
