# PRDs — message queue & IAM evaluation

We evaluated adding, "for completeness," a proper **durable message queue** and
**proper IAM** (identity + authorization) to the workshop. Each option was
researched against current 2026 releases and weighed against three hard
constraints: the **4-hour clock**, the **~16 GB laptop / 6 GiB worker container**,
and the workshop's **focus** (assembling a platform, not teaching messaging or
authz theory). The workshop already carries ~10 tools.

## Verdicts at a glance

| Candidate | Verdict | Why |
|---|---|---|
| **Durable MQ → NATS JetStream** | ✅ **Build — demo/stretch** | Light (~256 MiB), one great teaching beat, no re-plumbing required. [PRD-0001](0001-durable-messaging-nats.md) |
| **Identity/SSO → Dex** (not Zitadel) | ✅ **Build — hands-on stretch** | ~40 MiB, no DB, real paste-and-restart integrations; fills the "minus IAM" gap honestly. [PRD-0002](0002-platform-sso-dex.md) |
| Identity → **Zitadel** | ❌ Defer (verbal mention) | 3-workload stack, own DB, minutes-long first boot, leaky login pod — buys production features we can't exercise in 4h. The SSO *lesson* is IdP-agnostic, so Dex teaches the same thing at 1/20th the weight. |
| Authorization → **SpiceDB** | ❌ Defer (demo-taste only) | A real integration is 60–90 min of portal code + a deep ReBAC concept. The on-topic authz story ("who can touch which namespace") is **Kubernetes RBAC** — zero cost, already in the platform. SpiceDB is a great *standalone* authz workshop, a tangent inside a platform-assembly one. |

## A note on the RAM constraint

An earlier reading put the worker at "3.8 GiB used, ~2.2 GiB free." That number
was inflated — it came from `docker stats`, which counts reclaimable page cache
(mostly from pulling ~15–20 GB of images), not the real working set. The true
idle floor is being re-measured via the kubelet summary API (`workingSetBytes`).
**None of the verdicts above hinge on RAM** — they rest on time, complexity, and
teaching focus — but the correction matters: the two we're building (Dex ~40 MiB +
NATS ~256 MiB ≈ 300 MiB combined) are a rounding error against any honest headroom.

## Recommended shape

Both builds land as **stretch modules** (after the core 00–05 path), so they
enrich without crowding the 4-hour core:

- **Module 10 — Durable messaging** (NATS): mostly instructor-led demo; the
  "kill the broker, watch in-memory drop vs JetStream replay" contrast.
- **Module 11 — Platform SSO** (Dex): genuinely hands-on — one issuer, wire
  Grafana + Gitea + ArgoCD to trust it, log in once. Optionally give the
  bespoke portal real OIDC login (replacing its workshop-grade static creds).

Neither is promised in the published abstract, so both are honestly "extra."
Build only if the core path + stretch 06–09 are rock-solid first (they're in
active rehearsal — see issue #8).
