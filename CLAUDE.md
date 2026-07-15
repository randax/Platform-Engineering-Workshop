# Repo guide for AI agents

This is the **JavaZone 2026 workshop** "Cloud on Your Terms: Building Your Own
Cloud-Native Platform" (240 min, hands-on). Attendees build a full platform —
Talos-in-Docker, Cilium, in-cluster Gitea + ArgoCD, CNPG, RustFS, Crossplane v2 —
on their own laptops. Working offline after image pre-pull is a hard requirement.

## Authoritative documents — read before changing anything substantial

- **PLAN.md** — the construction plan: modules, timeline, decisions, risks.
- **docs/RESEARCH.md** — grounded, verified version/verdict decisions. If you think a
  version or approach is wrong, check here first; it probably was chosen deliberately.
- **docs/PRINCIPLES.md** — 15 design rules every lab and script must follow
  (outcome-oriented labs, verify.sh exit-0 contract, layered hints, offline-first,
  honest specs). When a lab violates a principle, fix the lab.

## Repository layout

```
scripts/     dev-setup.sh · cloudbox-init.sh · install.sh --check · create-cluster.sh
             bootstrap-gitops.sh · seed-gitea.sh · catch-up.sh <module> · kind-fallback.sh
gitops/      apps/       ArgoCD app-of-apps root — what is actually enabled
             catalog/    available capabilities (attendees copy catalog/<x>.yaml → apps/)
             components/ per-component manifests/values, sync-waved
lab/         00-setup … 09-capstone — outcome + verify.sh + layered hints (+ faults/ in 05)
solutions/   canonical end-state per module (what catch-up.sh force-pushes to Gitea)
apps/        first-party Go apps: cloudbox-portal (Console, module 08), uploader +
             resizer (picture pipeline, module 09) — built to GHCR by build-images.yaml
docs/        RESEARCH.md · PRINCIPLES.md
slides/      Slidev deck
.devcontainer/  Codespaces lifeboat — same content when local preflight fails
```

## Architecture contract

- **Single source of version pins: `scripts/versions.env`** (plus pinned `mise.toml`).
  Never introduce `:latest` or a second place where a version is written down.
- Pinned stack: Talos **v1.13.6** (never 1.12.x), Cilium **1.19.5**, ArgoCD **v3.4.5**,
  Crossplane **v2**, CloudNativePG, RustFS (standalone, beta — SeaweedFS is Plan B),
  Knative + Kourier (stretch), Argo Workflows + BuildKit + Zot (stretch),
  NATS JetStream (durable messaging, stretch), Backstage CNOE image (stretch),
  Victoria stack — VictoriaMetrics/Logs/Traces + Grafana — with the OTel Collector
  (observability, enabled on-demand from the catalog, not wave-0).
- Cluster: `talosctl cluster create docker`, 1 CP + 1 worker, raised memory limits,
  `cni: none` + Helm-installed Cilium.
- GitOps write path: ArgoCD points **only at the in-cluster Gitea** (single-pod SQLite,
  push-create, seeded by seed-gitea.sh) — never at GitHub.
- **Progressive-enable mechanic:** capabilities ship as ArgoCD Application manifests in
  `gitops/catalog/`; attendees enable one by copying it to `gitops/apps/` and pushing to
  Gitea. App-of-apps with sync waves; Application CRD health check restored in argocd-cm;
  `ServerSideApply=true` on CRD-heavy apps.
- One namespace per platform component, defined in that component's manifests under
  `gitops/components/`.
- All images pinned and hosted on GHCR (Docker Hub is rate-limited at the venue);
  `cloudbox-init.sh` pre-pulls them.

## Conventions

- Labs state **outcomes, not steps**; each ships `verify.sh` (exit 0 on success,
  `FAIL:`-prefixed actionable messages) and `solve.sh`, designed for CI regression
  against each other (job tracked in issue #10).
- Hints are layered and collapsed in `<details>` blocks; full solution is the last layer.
- Shell scripts: bash, `set -euo pipefail`, shellcheck-clean, idempotent, check-only
  flags never mutate.
- Facts matter to this audience: RustFS is an Apache-2.0 *alternative* to MinIO, whose
  open-source community edition was discontinued in 2025–26 in favor of the proprietary
  AIStor. Never write "MinIO went proprietary" or call RustFS a "successor".

AGENTS.md and .github/copilot-instructions.md carry this same guide for other tools;
keep them in sync with this file (AGENTS.md is a symlink to it).
