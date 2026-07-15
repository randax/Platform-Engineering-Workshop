# PRD-0004 — Progressive Cloudbox Console (features unlock as you build)

**Status:** Proposed (console enhancement) · **Verdict:** Build — after the golden path
**Depends on:** Cloudbox Console (module 08) · `internal/kube/workshop.go` `EvaluateModules` (already infers module state) · Application XR ([PRD-0003](0003-golden-path-application-xr.md), for the New Application page) · NATS ([PRD-0001](0001-durable-messaging-nats.md), for the Streams page)

## Problem

The console shows every page at once, whether or not the capability behind it
exists yet. Before module 06 the Services page has no Knative to list; before
NATS there are no streams. Worse, it wastes the single best teaching device the
console has: the platform's surface area literally *grows* as you install
capabilities, and the console could make that visible. Right now it doesn't.

## Goal & non-goals

**Goal:** the console reveals features as the attendee's cluster gains the
capability behind them — a live progress mechanic that's *honest* (a page appears
because its API now exists, not because a timer fired). Locked features tease
what's coming; newly-unlocked ones celebrate.

**Non-goals:** gamification for its own sake; fake gating; blocking access to
anything (locked pages explain, they don't punish); rebuilding the nav framework
(reuse the existing page registry).

## Design

**The mechanic.** Each registered page gains an optional **unlock predicate** — a
function of the same `Snapshot` that `EvaluateModules` already builds from live
cluster state. The nav renderer (`internal/web/registry.go`) draws each item in
one of three states:

- **Unlocked** — capability detected → full feature.
- **Locked** — greyed with 🔒 and *"Unlocks after Module 06 — Serverless"*;
  clicking opens a one-paragraph teaser of what it will do.
- **Just unlocked** — an htmx poll on the workshop snapshot fires a toast:
  *"🎉 Knative detected — the Functions page is now live."*

**Why it's the right kind of gimmick — it's true.** The console can't render a
Functions page before Knative exists because there's no `serving.knative.dev` API
to call. The locked menu isn't theater; it's the platform's real surface growing
under the attendee's hands. It makes concrete the module-08 lesson: *the portal
has no special powers — it only surfaces APIs that already exist.* The Workshop
page becomes the room's shared, self-updating map.

**New pages to unlock** (the console already has Overview, Components, Billing,
Activity, Workshop, Services, Databases, Gallery, Grafana):

| Unlocks after | Page | Shows |
|---|---|---|
| 03 Data | **Buckets** | RustFS bucket list + object browser + a presigned-URL button (the "download link, zero AWS" win) |
| 06 Serverless | **Functions** (extend Services) | scale-to-zero state, revisions, an Invoke button, cold-start timer |
| 07 CI | **Builds + Registry** | Argo Workflow runs/logs + a Zot catalog browser |
| NATS | **Streams** | JetStream streams, consumer lag, message counts — messaging you can inspect |
| 04 → golden path | **New Application** | the apex form + templates (shared with PRD-0003) |
| any | **Who am I / Access** | the console's own ServiceAccount permissions — reinforces "read-only on exactly 4 resources" (module 05 / RBAC) |

All read-only except New Application (which creates an `Application` XR, exactly as
the New Database form creates a `WorkshopDatabase` today). Each new read verb is
added to the console's ClusterRole explicitly and shown on the Who-am-I page.

## Cost

- **RAM/components:** none — same one Go binary.
- **Build effort:** the unlock mechanic (predicate + three nav states + toast) is
  the core, ~a day. Each new page is incremental and independently shippable; the
  read-only ones are small (list an API, render a table), New Application is shared
  with PRD-0003, Streams depends on NATS.
- **Workshop clock:** zero new lab time — it's ambient. Attendees *notice* pages
  lighting up as they work; the deep dive (reading the predicate) is take-home.

## Risks

- **Predicate honesty** — a feature must unlock on a real capability signal, not a
  proxy that can be true too early (same discipline `EvaluateModules` already
  keeps). Cover with the existing workshop-inference tests.
- **RBAC creep** — each new page needs read on a new resource; keep the ClusterRole
  minimal and visible (that's what the Who-am-I page is for).
- **Scope** — resist making it a full cloud console; ship page-by-page, each behind
  its unlock, each its own PR.

## Decision

**Build after the golden path**, since the **New Application** page is the hinge
shared with PRD-0003 and **Streams** needs NATS. Order: land the unlock mechanic +
locked/teaser/toast on the *existing* pages first (immediate delight, no new APIs),
then add Buckets → Functions → Builds/Registry → Streams → Who-am-I as the
capabilities land. Each is its own reviewable PR.
