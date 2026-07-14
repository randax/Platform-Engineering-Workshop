# PRD-0002 — Platform SSO with Dex

**Status:** Proposed (stretch module) · **Verdict:** Build, hands-on stretch
**Depends on:** stable core · **Not in the published abstract**

## Problem

Every UI in the platform — ArgoCD, Grafana, Gitea, the Cloudbox Console — uses
its own workshop-grade static credentials. The workshop deliberately scoped out
IAM, but the result is that attendees never see the single most common
platform-engineering capability: **one identity, single sign-on across the whole
platform.** This is the honest gap behind "cloud on your terms — minus IAM."

## Goal & non-goals

**Goal:** stand up one OIDC issuer and make ArgoCD, Grafana, and Gitea all trust
it, so an attendee logs in *once* and that identity flows everywhere. Optionally,
give the bespoke portal real OIDC login so they see the auth-code flow the
config-driven tools hide.

**Non-goals:** a production IdP with orgs/roles/self-service; teaching OAuth2
theory in depth; Backstage SSO (its TypeScript auth must be pre-baked, never
built live).

## Why Dex, not Zitadel / Keycloak

The SSO *lesson* is **identity-provider-agnostic** — ArgoCD, Grafana, Gitea, and
the portal only need an OIDC issuer URL + client credentials; they do not care
which IdP is behind it. So the IdP choice is purely a footprint/complexity call:

| IdP | Idle RAM | DB pod? | Ready in | Verdict here |
|---|---|---|---|---|
| **Dex** | **~40 MiB** | **none** (CRD storage) | seconds | ✅ **use this** |
| Zitadel v4 | ~700 MiB–1 GiB (core + login + PG) | yes (can reuse CNPG) | minutes (init/setup jobs) | ❌ buys production features we can't exercise in 4h |
| Keycloak | ~750 MiB–1.25 GiB (JVM) | yes | minutes | ❌ heaviest |

Dex with `enablePasswordDB: true` + a couple of `staticPasswords` is a *real
enough* IdP — its own login page and user store, so attendees log in with no
upstream. Its `staticClients` list issues tokens to many downstream apps — the
multi-app SSO story exactly. Add an upstream connector (GitHub/OIDC) and the same
one tool demonstrates **federation/brokering** too.

> Mention Zitadel/Keycloak verbally as "the production-grade version, and why
> lightweight brokers like Dex exist" — but don't spend the 4 hours on an IdP's
> own operability instead of the SSO lesson.

## Design

**Component:** standalone **Dex**, official Helm chart, CRD storage (no DB),
one Deployment. Vendor into `gitops/components/dex/` + `gitops/catalog/dex.yaml`.
Config: 2–3 static users, `staticClients` for grafana / argocd / gitea / portal.

> Run a *standalone* Dex — don't try to reuse the one ArgoCD bundles; that
> instance is effectively locked to ArgoCD's own auth. "You've already met Dex
> inside ArgoCD" is a nice hook, but a clean shared Dex serves the whole platform.

**Integrations, in order of reliability (all paste-and-restart):**
1. **Grafana** — `GF_AUTH_GENERIC_OAUTH_*` env vars. ~5–10 min.
2. **Gitea** — add an OAuth2 auth source (admin UI/CLI). ~5–10 min.
3. **ArgoCD** — `oidc.config` in `argocd-cm` + a group→role line in
   `argocd-rbac-cm`. ~10–15 min.
4. **Cloudbox Console (optional, the "under the hood" build):** add
   `coreos/go-oidc` + `oauth2` (~100 lines) so attendees see the
   auth-code/callback/verify flow — and it replaces the portal's static creds
   with real login, closing the "minus IAM" gap in the one app we own.

## Cost

- **RAM:** ~40 MiB (Dex) + the OIDC client bits are free. Negligible.
- **Time:** ~30–40 min hands-on for Dex + the three config integrations; +15–20
  for the portal OIDC build if included.
- **Build effort:** ~1 evening to vendor + catalog Dex with the client config;
  ~1 evening for the portal OIDC code (optional) + the lab writeup.
- **Images to pre-pull:** `dexidp/dex:<pinned>`.

## Risks

- Self-signed / in-cluster TLS quirks on the OIDC discovery URL between apps —
  **mitigated** by plain-HTTP in-cluster issuer (workshop-grade, like the rest).
- ArgoCD already runs a Dex; be explicit that this is a *separate* standalone
  instance to avoid confusion.
- Portal OIDC is the only real code; keep it optional so the module lands even
  if that part is cut for time.

## Decision

**Build as a hands-on stretch module.** Of the three IAM-ish options evaluated,
this is the strongest: light, reliable, genuinely hands-on, on-theme (SSO *is*
platform engineering), and it's the honest way to address the "minus IAM" gap —
in the one app we control, with real login, at ~40 MiB.

## Companion note: authorization

Identity (this PRD) answers *who are you*. For *what may you do*, the on-topic,
zero-cost answer is **Kubernetes RBAC** — which the platform already uses
throughout (the portal's least-privilege ClusterRole is a live example). If a
taste of modern relationship-based authz is wanted, run **SpiceDB demo-only**
(`--datastore-engine memory`, ~256 MiB, show the schema + a couple of
`zed permission check` calls, ~15 min) — but a full SpiceDB portal integration
(60–90 min of app code + a deep ReBAC model) belongs in a dedicated authz
workshop, not this one.
