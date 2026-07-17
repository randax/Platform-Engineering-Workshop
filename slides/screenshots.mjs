// Screenshot the console pages for docs/slides. Normally you don't run this
// directly — `./scripts/screenshots.sh` does the whole flow (render → shoot →
// copy into docs/screenshots/). This script is just step 2 (the shooter).
//
// It takes the standalone HTML the Go render test writes (CSS inlined,
// SCREENSHOTS=1 … go test -run Screenshots ./internal/web/) and shoots each to a
// PNG: a light + dark desktop shot per page, narrow shots for the monitoring
// page (responsive rail), and the CSS-only modals opened in each of their states.
//
// Usage:  node slides/screenshots.mjs <html-dir> <png-out-dir>
// It lives in slides/ so `import 'playwright-chromium'` (slides' devDependency)
// resolves against slides/node_modules with no NODE_PATH juggling; it falls back
// to a plain `playwright` install if that's what's on hand.
let chromium;
try {
  ({ chromium } = await import('playwright-chromium'));
} catch {
  ({ chromium } = await import('playwright'));
}
import { readdirSync } from 'node:fs';
import { basename, join } from 'node:path';

const [htmlDir, outDir] = process.argv.slice(2);
if (!htmlDir || !outDir) {
  console.error('usage: node scripts/screenshots.mjs <html-dir> <png-out-dir>');
  process.exit(1);
}

const browser = await chromium.launch();

// --- Page shots: one HTML file → light + dark desktop (+ mobile for monitoring).
const files = readdirSync(htmlDir).filter((f) => f.endsWith('.html'));
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

// --- Modal shots: the CSS-only modals are hidden until their checkbox is checked,
// and the New-application source picker swaps fields via :has(). Open each modal
// and (where relevant) select each source, so the docs show every state. Keyed
// by the modal's checkbox id; `source` null = just open it. Output names match
// docs/screenshots/console-*.png (see screenshots.sh copy map).
const MODALS = {
  'applications.html': {
    toggle: 'app-modal',
    shots: [
      ['new-application', 'image'], // prebuilt container image (default)
      ['deploy-from-source', 'repo'], // build from a Gitea repo (app-team golden path)
      ['scaffold-from-template', 'template'], // console scaffolds a repo (PRD-0012)
    ],
  },
  'services.html': {
    toggle: 'fn-modal',
    shots: [['new-function', null]], // build-and-deploy a function
  },
};
for (const [file, { toggle, shots }] of Object.entries(MODALS)) {
  if (!files.includes(file)) continue;
  const url = 'file://' + join(htmlDir, file);
  for (const [name, source] of shots) {
    for (const [suffix, colorScheme] of [['', 'light'], ['-dark', 'dark']]) {
      const page = await browser.newPage({ viewport: { width: 1280, height: 900 }, deviceScaleFactor: 2, colorScheme });
      await page.goto(url, { waitUntil: 'networkidle' });
      await page.evaluate(({ toggle, source }) => {
        document.getElementById(toggle).checked = true; // reveal the modal
        if (source) {
          const r = document.querySelector(`input[name="source"][value="${source}"]`);
          if (r) r.checked = true; // :has() swaps to this source's fields
        }
      }, { toggle, source });
      await page.waitForTimeout(150);
      await page.screenshot({ path: join(outDir, name + suffix + '.png'), fullPage: true });
      await page.close();
    }
    console.log('shot', name, '(modal)');
  }
}

await browser.close();
