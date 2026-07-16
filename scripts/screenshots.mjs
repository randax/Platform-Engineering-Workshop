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
  // Desktop, plus a narrow shot for the detail page to show the rail collapse.
  const shots = [[1280, '']];
  if (name.includes('monitoring')) shots.push([430, '-mobile']);
  for (const [width, suffix] of shots) {
    const page = await browser.newPage({ viewport: { width, height: 900 }, deviceScaleFactor: 2 });
    await page.goto('file://' + join(htmlDir, f), { waitUntil: 'networkidle' });
    await page.screenshot({ path: join(outDir, name + suffix + '.png'), fullPage: true });
    await page.close();
  }
  console.log('shot', name);
}
await browser.close();
