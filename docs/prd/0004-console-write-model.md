# DR-0004 — The platform's write model: two planes

**Type:** Decision record · **Status:** Accepted (2026-07-17) · **Applies to:** the Cloudbox Console, the labs, and the slides

## Decision

The platform has **two write planes**, split by *audience* — and we make that split explicit rather than mixing it per-action:

> **Git changes the platform. The console uses the platform. `kubectl` inspects both.**

| Plane | Path | Who / what | Why this path |
|---|---|---|---|
| **Platform plane — GitOps** | `git push → Gitea → ArgoCD → cluster` | the platform *operator*: installing capabilities, the catalog, **RBAC / capability grants**, cluster infra | low-frequency, high-blast-radius changes that want audit + rollback + a declarative source of truth. This is where GitOps *earns its cost*. You drive it with **git on the CLI**, and the console **reflects** it (Components / Access pages light up). The console never sends you to Gitea's web UI. |
| **Tenant plane — Console-direct** | `form → k8s API` (no git) | the platform *user*: create a database, deploy a function/app, make a bucket, **create a project** | high-frequency, low-blast-radius self-service that wants *instant* feedback. Straight to the API server, `kubectl create`–style — which is exactly what the console's database/function/app create forms already do. |
| **Inspect / escape hatch** | `kubectl` | anyone, debugging either plane | orthogonal to both; modules 01–05 build this muscle. |

## Context

We evaluated whether the console should mutate the cluster **directly** (k8s API), be **read-only** with all writes via git, or act as a **git frontend** (console → Gitea API → ArgoCD). The last option was proposed for "create project" (PRD-0011) to keep the portal non-admin.

Criteria, from a developer's point of view: directness (hops per action), feedback loop, git benefits (audit/rollback/declarative), **success rate / failure modes**, teaching honesty, and portal privilege.

| Criterion | A. Console-direct | B. Read-only + git CLI | C. Console→Gitea→Argo |
|---|---|---|---|
| Directness | ✅ 1 hop | ⚠️ 2 tools | ⚠️ hidden commit |
| Feedback loop | ✅ instant | ❌ sync-lag | ❌ sync-lag |
| Git benefits (tenant resources) | ❌ none | ✅ full | ✅ full |
| Success rate / failure modes | ✅ high (k8s *is* the store) | ❌ drift, sync lag, conflicts | ⚠️ argo moving parts |
| Teaching honesty | ✅ real portals hit an API | ⚠️ a portal that can't act is weak | ✅ real but heavyweight |
| Portal privilege | ⚠️ scoped write per resource | ✅ read-only | ⚠️ needs a Gitea token |

**Model C loses despite being clever:** it pays git's latency + moving parts on the one thing a console is uniquely good at — immediate self-service — to buy an audit trail a **single-user disposable lab does not need**. Right pattern, wrong workshop. **Model A wins** on the criteria a developer actually feels (directness, feedback, "it just worked").

## Consequence for RBAC-sensitive actions (projects)

The only reason to reach for the git frontend was "the portal can't create namespaces without cluster-admin." Model A resolves it by separating **capability** from **action**:

- **Capability grant = GitOps.** The attendee hands the portal a *scoped* `ClusterRole` (create namespaces; create `RoleBinding`s that bind **only** the pre-existing tenant grant) via the same one-time "hand the portal its keys" git step already used for databases/functions. Explicit, auditable, scoped — the security lesson is intact.
- **Action = Console-direct.** "New project" `POST`s a `Namespace` + one `RoleBinding`; it appears instantly.

**Grant via git; act via console.** The portal never becomes cluster-admin, and there is no Gitea round-trip in the hot path.

## What stays

The GitOps-vs-console-write *contrast* remains a **module 08 "going deeper" teaching beat** ("here's the other way, and its trade-offs") — an optional lens, not the default write path. GitOps is not diminished; it is placed where it earns its keep (the platform layer), and the console is placed where it earns its keep (self-service).

## Implications

- **Console:** tenant create/update/delete stay direct-to-API (as they already are). No console→Gitea write path is built.
- **PRD-0011 (projects):** revised to console-direct create behind a scoped, git-delivered `ClusterRole` grant (was: Gitea-API-backed). See the issue.
- **Slides/docs:** state the two-plane model explicitly (module 08); it is already *true today* (database/function creates are console-direct).
