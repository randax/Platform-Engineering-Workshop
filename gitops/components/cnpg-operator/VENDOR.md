# Vendored: cnpg-operator (CloudNativePG)

| | |
|---|---|
| Source | https://github.com/cloudnative-pg/cloudnative-pg |
| Version | **1.28.4** (latest 1.28.x patch, 2026-06-29; verified 2026-07-13. 1.29.2/1.30.0 exist — 1.28 chosen as the mature minor, matching the researched pin) |
| File | `cnpg-1.28.4.yaml` — **verbatim upstream, no edits** |

## Re-vendor

```sh
curl -sL -o cnpg-1.28.4.yaml \
  https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.28.4/cnpg-1.28.4.yaml
```

Notes:
- Creates its own `cnpg-system` namespace (also in the Application as
  destination + CreateNamespace; harmless overlap).
- CRDs are far beyond the 262KB client-side-apply annotation limit — the
  Application uses `ServerSideApply=true`.
- Operator default Postgres image (compiled into 1.28.4):
  `ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie` — pre-pull it; the
  backstage component pins the same image explicitly.

Images used:
- `ghcr.io/cloudnative-pg/cloudnative-pg:1.28.4`
- `ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie` (default for `Cluster` resources)
