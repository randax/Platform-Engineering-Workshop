# Workshop slides — JavaZone 2026

The [Slidev](https://sli.dev) deck for **Cloud on Your Terms: Building Your Own
Cloud-Native Platform** (JavaZone 2026). The deck frames the hands-on labs in
[`../lab/`](../lab/) — it never competes with them: short framing per module, a GO slide
with the verify command, and the spoken narrative in presenter notes.

## Run it

```bash
cd slides && npm install

npm run dev                  # develop at http://localhost:3030
npm run dev -- --presenter   # presenter mode (notes + next slide)
npm run build                # static site in dist/
npm run export               # PDF (needs: npx playwright install chromium)
```

Or via mise from the repo root: `mise run slides:dev`, `slides:presenter`,
`slides:build`, `slides:export`.

## Structure

```
slides/
├── slides.md            # headmatter + cover, imports pages/ in order
├── pages/
│   ├── why.md           # the sovereignty hook + architecture diagram
│   ├── how.md           # module map, lab contract, help, AI policy
│   ├── module-00.md …   # per-module: section divider → concept → GO slide
│   │   module-10.md     # (03: MinIO/RustFS interlude · 08: build-vs-buy + Backstage demo
│   │                    #  · 10: escalation ladder + the small-model cliff)
│   └── closing.md       # what you built, take it home, thanks
└── styles/index.css     # gradient backgrounds, accent color, badges
```

## Conventions (keep them when editing)

- **Presenter notes carry the words.** Every content slide ends with an HTML comment —
  that's what the speakers rehearse from. Slides stay sparse: ≤5 bullets, short lines.
- **Offline-safe.** No external images, fonts, or CDN assets (`fonts.provider: none`;
  backgrounds are CSS gradients in `styles/index.css`). The deck must render without
  internet, like everything else in this workshop.
- **Diagrams are Mermaid** code blocks — no image files.
- **Layouts** come from the seriph theme: `cover`, `section` (module dividers), `fact`
  (big statements/breaks), `two-cols`, and default.
- **Ecosystem accuracy matters** (see `../docs/PRINCIPLES.md`, rule 15) — e.g. the
  MinIO/RustFS wording in module 03 is deliberate; don't "simplify" it.

## Deploy

Deployed automatically to GitHub Pages on every `slides/` change on `main`
(`.github/workflows/slides.yaml`): https://randax.github.io/Platform-Engineering-Workshop/
