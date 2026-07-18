#!/usr/bin/env bash
# Regenerate the console screenshots in docs/screenshots/ — end to end, one command.
#
#   ./scripts/screenshots.sh
#
# Three steps, no manual copying:
#   1. render the REAL templates + style.css to standalone HTML (a Go test), so
#      the shots stay faithful to the shipped UI;
#   2. shoot each with headless Chromium (Playwright) — light + dark, the mobile
#      nav, and every CSS-only modal opened in each of its states;
#   3. copy the canonical set into docs/screenshots/.
#
# Requires Go, Node, and Playwright's Chromium. The browser comes from slides'
# `playwright-chromium` devDependency; this script installs it if it's missing.
# Review the result with `git status docs/screenshots/` before committing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHOTS="$(mktemp -d)"
trap 'rm -rf "$SHOTS"' EXIT

echo "==> 1/3  render templates to self-contained HTML"
( cd "$ROOT/apps/portal" && SCREENSHOTS=1 SCREENSHOTS_DIR="$SHOTS" \
    go test -run Screenshots ./internal/web/ )

echo "==> 2/3  shoot with headless Chromium"
if [ ! -d "$ROOT/slides/node_modules/playwright-chromium" ]; then
  echo "    installing playwright-chromium (slides devDependency)…"
  ( cd "$ROOT/slides" && npm install && npx playwright install chromium )
fi
# The shooter lives in slides/ so `import 'playwright-chromium'` resolves against
# slides/node_modules on its own — no NODE_PATH needed.
node "$ROOT/slides/screenshots.mjs" "$SHOTS" "$SHOTS"

echo "==> 3/3  copy the canonical set into docs/screenshots/"
DEST="$ROOT/docs/screenshots"
# generated-base : docs-base. A light + -dark pair is copied for each. Keep this
# list in sync with the Go pages list (component_detail_test.go) and the modal
# config in screenshots.mjs.
pairs="
component-detail-monitoring:console-component-monitoring
component-detail-locked:console-component-locked
components:console-components
applications:console-applications
application-detail:console-application-detail
function-detail:console-function-detail
services:console-services
database-detail:console-database-monitoring
builds:console-builds-monitoring
streams:console-streams-monitoring
buckets:console-buckets-monitoring
new-application:console-new-application
deploy-from-source:console-deploy-from-source
scaffold-from-template:console-scaffold-from-template
new-function:console-new-function
"
for p in $pairs; do
  src="${p%%:*}"; dst="${p##*:}"
  for suffix in "" "-dark"; do
    [ -f "$SHOTS/$src$suffix.png" ] && cp "$SHOTS/$src$suffix.png" "$DEST/$dst$suffix.png"
  done
done
# Mobile-only shots (light only).
cp "$SHOTS/component-detail-monitoring-mobile.png"     "$DEST/console-component-monitoring-mobile.png" 2>/dev/null || true
cp "$SHOTS/component-detail-monitoring-mobile-nav.png" "$DEST/console-mobile-nav-open.png"             2>/dev/null || true

echo "✅ done — review with:  git status docs/screenshots/"
