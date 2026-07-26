# Vendored technology logos

These SVGs are **vendored on purpose**: the deck runs fully offline at the venue
(`slides.md` sets `fonts.provider: none` and forbids CDN assets), so every logo
is bundled at build time and served from `/logos/*.svg` — never fetched at
runtime. Use them through the `<Logo>` component (`slides/components/Logo.vue`).

## Why logos at all
"Cloud on Your Terms" argues these open-source projects *are* the cloud. The
audience should **recognise** them on sight — that's the credibility payload, so
the "you run today" column and every module divider carry the real marks.

## Sources & licensing
Project logos are trademarks of their respective owners, used here **nominatively**
(to identify the technology in an educational talk) — not to imply endorsement.
CNCF project marks are shared under the CNCF's usage terms; the rest come from
each project's own brand assets or a permissive icon set.

| File | Represents | Source |
|------|-----------|--------|
| `kubernetes.svg` | Kubernetes | CNCF artwork (color icon) |
| `cilium.svg` | Cilium | cilium/cilium `Documentation/images/logo-solo.svg` |
| `argo.svg` | Argo family (Argo CD, Argo Workflows) | CNCF artwork (color icon) |
| `crossplane.svg` | Crossplane | CNCF artwork (color icon) |
| `knative.svg` | Knative | CNCF artwork (color icon) |
| `nats.svg` | NATS | CNCF artwork (color icon) |
| `opentelemetry.svg` | OpenTelemetry | CNCF artwork (color icon) |
| `cloudnativepg.svg` | CloudNativePG | CNCF artwork (color icon) |
| `gitea.svg` | Gitea | go-gitea/gitea `public/assets/img/logo.svg` |
| `grafana.svg` | Grafana | devicon (grafana-original) |
| `docker.svg` | Docker | devicon (docker-original) |
| `cloudbox.svg` | Cloudbox Console (this project's own mark) | original — traced from Hans's mockup, flat isometric box + cloud |
| `buildkit.svg` | BuildKit (Moby) | devicon (docker-original — BuildKit is a Moby project) |
| `talos.svg` | Talos Linux | Simple Icons |
| `victoriametrics.svg` | VictoriaMetrics | Simple Icons |
| `amazonwebservices.svg` | AWS (rent column, dimmed) | devicon (amazonwebservices wordmark) |
| `microsoftazure.svg` | Azure (rent column, dimmed) | devicon (azure-original) |
| `googlecloud.svg` | Google Cloud (rent column, dimmed) | Simple Icons |

Not vendored: **Zot** (no clean official SVG at build time) → rendered as a text
chip via `<Logo name="zot" text="zot" />`. **RustFS** likewise falls back to a
text chip. Re-vendor if/when an official mark is published.

## Re-vendoring
Logos are fetched once and committed. If a source URL rots, refetch from the
project's current brand page and update the row above. Keep them as SVG (crisp +
tiny + offline).
