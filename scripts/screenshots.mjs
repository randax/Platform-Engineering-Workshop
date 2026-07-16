// Screenshot the console pages for docs/slides. Two-step flow (see
// docs/screenshots/README.md):
//   1. the Go render test writes standalone HTML (CSS inlined) to a dir:
//        SCREENSHOTS=1 SCREENSHOTS_DIR=<dir> go test -run Screenshots ./internal/web/
//   2. this script shoots each *.html to a PNG (desktop, + a -mobile shot for
//        pages whose name contains "monitoring", to capture the responsive rail).
//
// Usage:  node scripts/screenshots.mjs <html-dir> <png-out-dir>
// Requires Playwright + Chromium:  npx playwright install chromium
import { chromium } from 'playwright';
import { readdirSync } from 'node:fs';
import { basename, join } from 'node:path';

const [htmlDir, outDir] = process.argv.slice(2);
if (!htmlDir || !outDir) {
  console.error('usage: node scripts/screenshots.mjs <html-dir> <png-out-dir>');
  process.exit(1);
}

const files = readdirSync(htmlDir).filter((f) => f.endsWith('.html'));
const browser = await chromium.launch();
for (const f of files) {
  const name = basename(f, '.html');
  // Every page gets a light + dark desktop shot (the console is theme-aware via
  // prefers-color-scheme, and the dark shots are the "wow" in the slides). The
  // monitoring detail page also gets narrow shots to show the mobile nav.
  const shots = [
    [1280, '', false, 'light'],
    [1280, '-dark', false, 'dark'],
  ];
  if (name.includes('monitoring')) {
    shots.push([430, '-mobile', false, 'light']); // collapsed: sticky bar + content
    shots.push([430, '-mobile-nav', true, 'light']); // expanded: after tapping the burger
  }
  for (const [width, suffix, openNav, colorScheme] of shots) {
    const page = await browser.newPage({ viewport: { width, height: 900 }, deviceScaleFactor: 2, colorScheme });
    await page.goto('file://' + join(htmlDir, f), { waitUntil: 'networkidle' });
    if (openNav) await page.locator('.nav-burger').click();
    await page.screenshot({ path: join(outDir, name + suffix + '.png'), fullPage: true });
    await page.close();
  }
  console.log('shot', name);
}
await browser.close();
