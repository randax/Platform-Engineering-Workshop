# Vendored: cnpg-operator (CloudNativePG)

| | |
|---|---|
| Source | https://github.com/cloudnative-pg/cloudnative-pg |
| Version | **1.28.4** (latest 1.28.x patch, 2026-06-29; verified 2026-07-13. 1.29.2/1.30.0 exist — 1.28 chosen as the mature minor, matching the researched pin) |
| File | `cnpg-1.28.4.yaml` — **verbatim upstream, no edits** |

## Curation: none

This component has **zero** workshop curation — the vendored file is the release
asset byte-for-byte (re-downloaded and diffed 2026-08-16: identical). Everything
workshop-specific lives outside the file: `ServerSideApply=true` +
`CreateNamespace=true` on `gitops/catalog/cnpg-operator.yaml` (sync-wave 1), and
the per-`Cluster` settings (image pin, `storageClass: local-path`, halved
resources) in whichever component ships the `Cluster` — see
`../backstage/VENDOR.md` and the module 04 composition.

So re-vendoring is a plain overwrite, and *any* diff against the upstream asset
is a defect, not a curation. Keep it that way: if a change ever seems necessary
here, put it in an ArgoCD sync option or a kustomize-free sibling file instead.

## Re-vendor

```sh
curl -sL -o cnpg-1.28.4.yaml \
  https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.28.4/cnpg-1.28.4.yaml
```

Verify it stayed verbatim (must print nothing):

```sh
curl -sL https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.28.4/cnpg-1.28.4.yaml \
  | diff - cnpg-1.28.4.yaml
```

The filename carries the version, so a bump renames the file. The ArgoCD
Application points at the *directory*, so nothing there changes — but delete the
old file (a leftover in the directory would be applied too) and update
`scripts/images.txt` in the same commit, or `check-consistency.sh` fails on the
uncovered image.

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
