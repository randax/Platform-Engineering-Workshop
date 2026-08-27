# Workshop Construction Plan — JavaZone 2026 (v2, grounded)

**Workshop:** Cloud on Your Terms: Building Your Own Cloud-Native Platform
**When:** JavaZone 2026 — conference Sept 2–3 (NOVA Spektrum, Lillestrøm); workshop day
likely Tue Sept 1 at Rebel Oslo (unconfirmed — ask organizers). 240-minute slot.
**Speakers:** Hans Kristian Flaatten, Øyvind Randa
**Grounding:** [docs/RESEARCH.md](docs/RESEARCH.md) (verified versions/verdicts, July 13 2026)
and [docs/PRINCIPLES.md](docs/PRINCIPLES.md) (design rules). v1 of this plan was
adversarially reviewed; this version incorporates that review.

## 0. The fire that is already burning 🔥

The conference page is **live** and tells attendees to run three scripts from this repo.
All three are broken today:

- `scripts/dev-setup.sh` runs `go mod download` — there is no `go.mod`. Fails for everyone.
- `scripts/install.sh` has no `--check` flag; `./scripts/install.sh --check` starts
  installing the *2025* stack (Kyverno, RedPanda, distributed MinIO…) into whatever cluster
  kubectl points at, then errors on files that don't exist.
- `scripts/cloudbox-init.sh` pre-pulls nothing (the prereq page says it does), needs an
  existing cluster, and hardcodes an egress rule to `192.168.5.1`.

**Week-1 deliverable, before anything else:** minimal honest versions of all three
(dev-setup = mise-based tool install; install --check = genuine check-only preflight;
cloudbox-init = pull a pinned image list), plus a README updated to 2026 that stops
advertising labs that don't exist. Also: commit this plan and docs/ — untracked files are
one `git clean` from oblivion.

## 1. Verdicts from research (details in docs/RESEARCH.md)

| Bet | Verdict |
|---|---|
| Talos-in-Docker + Cilium | **GO** — pin Talos v1.13.8 (never 1.12.x), raise node memory limits, scripted kind+Cilium fallback |
| RustFS | **Conditional GO** — pin ≥1.0.0-rc.1, standalone mode; SeaweedFS is the rehearsed Plan B with explicit switch triggers (mid-Aug) |
| GitOps write path | **In-cluster Gitea** (single-pod SQLite, push-create, seeded by Job); ArgoCD v3.5.x pinned, app-of-apps + sync waves; never point at GitHub |
| In-cluster builds | Kaniko is dead → **rootless BuildKit** + Zot registry; needs PSA-privileged build namespace on Talos; unrehearsed combo — spike early |
| Crossplane | **v2** (claims gone; compositions emit CNPG `Cluster` directly) — simpler to teach than v1 ever was |
| Backstage | Hands-on **is** feasible via CNOE prebuilt image — but heaviest item (~2 GB); last module + presenter fallback |
| Observability | On-demand Victoria stack (VictoriaMetrics/Logs/Traces + Grafana) + OTel Collector, not kube-prometheus-stack or single-pod otel-lgtm |
| RAM | Landing zone 13–17 GB → publish **16 GB min / 32 GB recommended** |
| Laptops | JavaZone 2022 precedent lost half the room to local setup → pre-flight gate + fallback path required (see Decision 1) |

## 2. Session design (240 min)

Budget: intro 35 (module 00 runs concurrently inside it) + one 10-min break + pivot 5 +
door block 45 + protected close 10 ⇒ **135 min of guided core modules**. Principle 10 says
plan half of what fits: **5 core modules + door 0**, every module = short framing → lab
(outcome + verify.sh + layered hints) → walk the solution to re-sync.

The room's copy of this table is `slides/pages/how.md` — the map slide and its notes are
derived from here, and each module's GO slide carries its timebox once. When a number moves,
move it in both, and nowhere else.

| Clock | Dur | Block | Type | Visible win |
|-------|-----|-------|------|-------------|
| 0:00 | 10 | Cover + why build your own cloud (Bruktby) | plenum | — |
| 0:10 | 3 | **Module 00 — pre-flight**, launched and left running | gate | `install.sh --check` all green |
| 0:13 | 22 | what · platforms (Nav) · stack · how — zero-keyboard, pre-flight runs underneath | plenum | — |
| 0:35 | 20 | **01** Talos cluster + Cilium — *"you now own a cloud"* | core | nodes Ready, Cilium green, no kube-proxy |
| 0:55 | 20 | **02** GitOps — Gitea + ArgoCD, bootstrap the platform tree | core | edit → push → watch ArgoCD converge |
| 1:15 | 20 | **03** Data services — CNPG Postgres + RustFS bucket via GitOps | core | psql into your own DBaaS; presigned URL works |
| 1:35 | 10 | Break — the day's only scheduled one | — | (pre-enable `backstage.yaml` on the projector cluster) |
| 1:45 | 20 | **04** Self-service — Crossplane v2 XR composes DB + bucket | core | one YAML → whole stack appears |
| 2:05 | 15 | **05** Fault injection + AI agent segment — diagnose, verify the agent's claim | core | faults 1 + 4 found, fixed, and the claim checked |
| 2:20 | 15 | **06** Knative — serverless, scale from zero | core | pods 0 → 1 → 0 around a `200` |
| 2:35 | 25 | **09 Capstone** — picture pipeline (enables `portal.yaml` too) | core finale | upload → resizer wakes → thumbnail + one trace |
| 3:00 | 5 | **Adventure pivot** — five doors pitched, door 0 recommended out loud | plenum | — |
| 3:05 | 45 | **Adventure block** (issue #193) — attendee picks a door; room self-paced, coffee at will | open-ended finale | a door's warm-up win inside ~15 min |
| 3:50 | 10 | **Close** — hard stop, before/after replay, take-home | plenum | the box, now full |

Guided total: 135 min (01–05 at 95, plus 06 and 09). Serverless and the capstone are
**core, not stretch**: a platform that cannot scale to zero and has nothing running on top
of it is not a complete platform, and the capstone is the day's payoff — everyone gets it,
not just the attendees who pick one door. The capstone's setup enables `portal.yaml`, so
every attendee ends the guided day with the Console running; module 08 is about *reading*
that Console, which is why it stays on door 0.

Door 0 = the marked trail = **modules 07 · 08 · 10** (in-cluster CI with Argo Workflows +
BuildKit + Zot · the Cloudbox Console's source · day-2 AI ops with kagent). It gets zero
plenary minutes and is the recommended default at the pivot; two opt-in projector demos run
*inside* the block (in-cluster build ~3:20, Backstage ~3:35). Observability stays on-demand
— enabled from the catalog as the capstone's "now observe what you built" step, not wave-0.

The lab timeboxes above are the fast-tempo profile: measured `solve.sh` times are 0:29–2:33
per module (docs/REHEARSALS.md), and the timeboxes are people-time on top of that. The
Phase-5 timed dry-run is what confirms or moves them.

The door block is deliberately the day's buffer: it grows if the core runs fast and shrinks
if it doesn't. The close never moves. Timeboxes are soft targets — we walk the solution when
the timer ends regardless, and `catch-up.sh` absorbs the variance (Principle 11).

## 3. Target architecture (what the repo must contain)

```
attendee laptop
└── talos-box VMs (primary, where `tbx doctor` passes) or Docker (≥10 GB, fallback)
    └── Talos v1.13.8 cluster (1 CP + 1 worker, raised memory)
        ├── Cilium 1.20 (CNI + shared ingress)
        ├── Gitea (single-pod SQLite, seeded from this repo)   ← the "cloud's" git
        ├── ArgoCD v3.5.x  ── app-of-apps w/ sync waves ──┐
        ├── CloudNativePG + demo Postgres                 │ everything below
        ├── RustFS (standalone)                           │ delivered as
        ├── Crossplane v2 + XRD/composition               │ ArgoCD apps from
        ├── Knative Serving + Kourier          (stretch)  │ the in-cluster
        ├── Argo Workflows + BuildKit + Zot    (stretch)  │ Gitea
        ├── Cloudbox Console (bespoke portal)  (stretch)  │
        ├── Knative Eventing + picture pipeline (capstone)│
        ├── Backstage (CNOE image, presenter demo)        │
        └── Victoria stack + OTel Collector (on-demand) ──┘
```

**Substrate.** Two backends behind one dispatcher (`scripts/create-cluster.sh` +
`scripts/substrate/{tbx,docker}.sh`): **talos-box** (`tbx`, real Talos VMs — Apple
Silicon macOS, Linux with KVM) is primary; **Talos-in-Docker** is the fallback and the
only substrate for Windows/WSL2, Codespaces and CI. The choice is resolved once
(`CLOUDBOX_SUBSTRATE` → `~/.cloudbox/substrate` → `CLOUDBOX_SUBSTRATE_DEFAULT` →
`tbx doctor`) and persisted at create. Both produce the *same* cluster: our own Talos
config, the same `cni: none` patch, the same Cilium.

**One hostname scheme, `*.cloudbox.k8s.test`,** served by a shared Cilium ingress: on tbx
via a real `LoadBalancer` VIP (`172.30.<n>.200`, L2-announced) that talos-box's resolver
already answers for; on Docker via NodePort 30880 published to host port 80 plus a marked
`/etc/hosts` block. Every browser-facing URL in the labs is a hostname, on both.

Repo layout to build toward:

```
scripts/          dev-setup.sh · install.sh --check · cloudbox-init.sh (image pre-pull)
                  create-cluster.sh · catch-up.sh <module> · kind-fallback.sh
gitops/           app-of-apps root + one dir per component (sync-waved)
lab/              NN-module/README.md (outcome + <details> hints) · verify.sh · solve.sh
                  faults/ (issue.yaml + fix.yaml + description.md)
solutions/        canonical end-state per module (what catch-up force-pushes to Gitea)
slides/           Slidev (exists, needs 2026 rewrite)
docs/             RESEARCH.md · PRINCIPLES.md
.devcontainer/    same environment in Codespaces/locally (the lifeboat path)
```

## 4. Work phases (re-dated; ~7 weeks left)

### Phase 0 — Stop the bleeding (week of July 13) ⚠️ already late
- [x] Fix the three published scripts (minimal honest versions) + pin mise.toml (no `latest`)
- [x] README → 2026: real lab list, honest specs (16/32 GB), supported-platform matrix,
      corrected MinIO/RustFS wording
- [x] Commit PLAN.md + docs/; remove dead scripts (Strimzi, MinIO, Tekton, duplicate CNPG)
- [ ] Email JavaZone organizers: workshop day/venue/seat cap/tables/power/wired network/SSH (issue #11)
- [x] Rename repo — done 2026-07-14, as `Platform-Engineering-Workshop` (year-neutral; old URLs redirect). ⚠️ Went public BEFORE the image publish — issue #7 sequence now urgent

### Phase 1 — Spike the unknowns (July → rehearsal; the full matrix is issue #8)
- [x] One-evening RustFS spike (standalone chart, presigned URLs) — shipped as the module 03
      component; presigned-URL flow green in the weekly bootstrap rehearsals (e.g. Aug 3 run)
- [x] BuildKit-rootless on Talos (PSA-privileged namespace) — module 07 ships it and the
      weekly bootstrap-test rehearses it in CI (first green full run Aug 3)
- [x] Knative + Kourier on Talos+Cilium — modules 06/09 run it end to end in the weekly CI
      rehearsal (scale-from-zero + eventing both exercised)
- [ ] Assemble the full stack once; measure real idle RAM; fix the published spec if needed
- [ ] WSL2 end-to-end run (least-verified platform)
- [x] Gitea seed + force-push catch-up mechanism — shipped (`seed-gitea.sh`, `catch-up.sh`),
      asserted by the CI recovery-path job since Aug 18

### Phase 2 — Platform tree + prereqs final (early August)
- [x] `gitops/` app-of-apps with sync waves, Application health check in argocd-cm,
      ServerSideApply/SkipDryRun where needed
- [x] `cloudbox-init.sh` final image list (pinned; preflight-verified via crane before download)
- [x] CI: shellcheck + yaml + kubeconform + consistency + Go tests on PR; weekly bootstrap
      workflow exists but is gated `continue-on-error` until first green run (issue #10)
- [ ] Announce updated prereqs to JavaZone (their page must match reality; after issue #7)

### Phase 3 — Labs (August)
- [x] Modules 00–09 in the outcome/verify/hints/solve pattern (05 = fault library incl. the
      AI-trap; 08 = bespoke Cloudbox Console; 09 = picture-pipeline capstone)
- [x] Catch-up flow per module (replace-not-overlay, convergence wait, chained post-steps)
- [ ] Git tags per module (nice-to-have; solutions/ + catch-up.sh already cover recovery)

### Phase 4 — Slides + helpers (mid-August)
- [x] Slidev rewrite: 55 slides, per-module framing, presenter notes, offline-safe,
      visually reviewed via PNG export (publish to Pages: issue #13)
- [ ] Recruit 4–8 helpers (CNCF/GDG networks); helper cheat-sheet of known failure modes

### Phase 5 — Rehearse + harden (last 2 weeks of August)
- [ ] Two timed full dry-runs (one on a clean machine, one driven by a guinea pig,
      one leg over phone hotspot); cut scope by timing data
- [ ] Offline test: airplane-mode laptop, everything from pre-pulled images
- [ ] Pre-record demo videos as last-resort fallback; final version pins; tag `javazone-2026`
- [ ] Merge PR #194 (tutor-mode CLAUDE.md/AGENTS.md swap) ~Aug 30 — two days ahead, after
      content freeze
- [ ] Adventure rehearsals (issue #193): cert-manager add, Kafka-with-heap-cap (go/no-go for
      the 32 GB tier), the security netpol arc against a live capstone, lab-01 manual-Cilium
      flow on a real laptop (CI covers it since Aug 24, a human hasn't)
- [ ] Final prework refresh announced (re-run `cloudbox-init.sh`) once issue #7 + the
      adventure images are published — the venue counts on it

## 5. Risks (updated)

| Risk | Mitigation |
|---|---|
| Attendees hit broken prereqs **today** | Phase 0 this week; support channel in README |
| Half the room can't run locally (2022 precedent) | Pre-flight gate + decision-1 fallback path + helpers |
| Docker Hub NAT rate-limit | Everything on GHCR, pinned; optional room registry mirror (registry-pi pattern) |
| RustFS immature | Explicit switch triggers mid-Aug → SeaweedFS; one-values-file change |
| BuildKit/Knative on Talos unrehearsed | Phase 1 spikes before any lab depends on them |
| 16 GB laptops OOM | Backstage last + demo fallback; Hubble presenter-only; honest published spec |
| Overrun | Soft timeboxes + `catch-up.sh`; the door block is the buffer and shrinks first; the close never moves; cut by dry-run data |
| Speaker illness | Both speakers rehearse *all* modules; slides + labs self-contained |
| Version drift July→Sept | Pin everything now; weekly CI bootstrap; re-verify pins late Aug |
| Unknown headcount (30 vs 80) | Ask organizers now; helper count scales with cap |
| **Substrate swap eight days out (accepted, gated).** The analysis in `docs/talos-box-vs-docker.md` recommended against it; the owner proceeded | The fallback is first-class and CI-proven, plus a hard go-live gate on Aug 31 that flips the default back with a one-line change (`CLOUDBOX_SUBSTRATE_DEFAULT` in `scripts/versions.env`) |

## 6. Decisions (made 2026-07-13, Hans)

1. **Environment strategy: local-first + devcontainer lifeboat.** Talos-in-Docker on the
   attendee's laptop is the primary path, gated by `install.sh --check`; the repo ships a
   devcontainer so pre-flight failures open the same content in GitHub Codespaces.
2. **Argo Workflows: projector demo + self-paced door-0 lab.** The build→Zot→deploy
   pipeline is demoed live inside the door block (opt-in, ~3:20); the lab stays in the repo
   for door-0 walkers and home use.
3. **AI segment: yes, as designed.** Module 5 ships with a seeded-fault library, agent-
   assisted diagnosis, and one fault where the obvious AI answer is wrong.
4. **Repo name: rename to `jz-2026-platform-engineering` now.** GitHub redirects the old
   URL printed on the conference page.
5. **Object storage: RustFS stays the default**, SeaweedFS is the rehearsed Plan B with the
   mid-August switch triggers in docs/RESEARCH.md.
6. **Bespoke portal + capstone pipeline** (decided 2026-07-14): module 08's hands-on is the
   bespoke Go+htmx **Cloudbox Console** (`apps/`, NodePort 30600) — small enough to read,
   honest about build-vs-buy; Backstage stays in the catalog as a 5-minute presenter demo
   inside module 08. New module 09 caps the day: Knative Eventing + a picture pipeline
   (portal gallery upload → CloudEvent → resizer scales from zero → thumbnail + metadata
   in RustFS, traced in Grafana).
