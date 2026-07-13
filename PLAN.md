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
| Talos-in-Docker + Cilium | **GO** — pin Talos v1.13.6 (never 1.12.x), raise node memory limits, scripted kind+Cilium fallback |
| RustFS | **Conditional GO** — pin ≥1.0.0-beta.8, standalone mode; SeaweedFS is the rehearsed Plan B with explicit switch triggers (mid-Aug) |
| GitOps write path | **In-cluster Gitea** (single-pod SQLite, push-create, seeded by Job); ArgoCD v3.4.x pinned, app-of-apps + sync waves; never point at GitHub |
| In-cluster builds | Kaniko is dead → **rootless BuildKit** + Zot registry; needs PSA-privileged build namespace on Talos; unrehearsed combo — spike early |
| Crossplane | **v2** (claims gone; compositions emit CNPG `Cluster` directly) — simpler to teach than v1 ever was |
| Backstage | Hands-on **is** feasible via CNOE prebuilt image — but heaviest item (~2 GB); last module + presenter fallback |
| Observability | Single `grafana/otel-lgtm` pod, not kube-prometheus-stack |
| RAM | Landing zone 13–17 GB → publish **16 GB min / 32 GB recommended** |
| Laptops | JavaZone 2022 precedent lost half the room to local setup → pre-flight gate + fallback path required (see Decision 1) |

## 2. Session design (240 min)

Budget: intro 15 + two breaks 20 + wrap-up/open tinkering 30 ⇒ **~175 min of modules**.
Principle 10 says plan half of what fits: **4 core modules + stretch material**, every
module = short framing → 10–15 min lab (outcome + verify.sh + layered hints) → walk the
solution to re-sync.

| # | Module | Time | Type | Visible win |
|---|--------|------|------|-------------|
| 0 | Why build your own cloud + pre-flight verify | 15 | plenum | `install.sh --check` all green |
| 1 | Talos cluster + Cilium — *"you now own a cloud"* | 35 | core | nodes Ready, Cilium status green |
| 2 | GitOps — Gitea + ArgoCD, bootstrap the platform tree | 35 | core | edit → push → watch ArgoCD converge |
| 3 | Data services — CNPG Postgres + RustFS bucket via GitOps | 35 | core | psql into your own DBaaS; presigned URL works |
| 4 | Self-service — Crossplane v2 claim composes DB + bucket | 35 | core | one YAML claim → whole stack appears |
| 5 | **Fault injection + AI agent segment** — break it, diagnose it (with or without an agent), verify the agent's claim | 25 | core/flex | found and fixed the seeded fault |
| S1 | Knative — deploy the app serverless | stretch | self-paced + demo | curl a scale-from-zero URL |
| S2 | Argo Workflows — in-cluster image build → Zot → deploy | stretch | presenter demo + self-paced lab | pipeline goes green |
| S3 | Backstage — CNOE portal, template → Gitea → ArgoCD loop | stretch | last module / demo | scaffold an app from the portal |
| — | Observability | woven | otel-lgtm installed in module 2's tree; "look at what you built" moments in every module | |

Core = 155 min + module 0 ⇒ fits with slack; stretch material absorbs the fast 20%.

## 3. Target architecture (what the repo must contain)

```
attendee laptop
└── Docker (≥10 GB)
    └── Talos v1.13.6 docker cluster (1 CP + 1 worker, raised memory)
        ├── Cilium 1.18/1.19 (CNI)
        ├── Gitea (single-pod SQLite, seeded from this repo)   ← the "cloud's" git
        ├── ArgoCD v3.4.x  ── app-of-apps w/ sync waves ──┐
        ├── CloudNativePG + demo Postgres                 │ everything below
        ├── RustFS (standalone)                           │ delivered as
        ├── Crossplane v2 + XRD/composition               │ ArgoCD apps from
        ├── Knative Serving + Kourier          (stretch)  │ the in-cluster
        ├── Argo Workflows + BuildKit + Zot    (stretch)  │ Gitea
        ├── Backstage (CNOE image)             (stretch)  │
        └── grafana/otel-lgtm                  ───────────┘
```

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
- [ ] Fix the three published scripts (minimal honest versions) + pin mise.toml (no `latest`)
- [ ] README → 2026: real lab list, honest specs (16/32 GB), supported-platform matrix,
      corrected MinIO/RustFS wording
- [ ] Commit PLAN.md + docs/; remove dead scripts (Strimzi, MinIO, Tekton, duplicate CNPG)
- [ ] Email JavaZone organizers: workshop day/venue/seat cap/tables/power/wired network/SSH
- [ ] Rename repo to `jz-2026-platform-engineering` (decision 4; old URL redirects)

### Phase 1 — Spike the unknowns (rest of July)
- [ ] One-evening RustFS spike (standalone chart, presigned URLs) — else flip to SeaweedFS now
- [ ] BuildKit-rootless on Talos (PSA-privileged namespace) — the unrehearsed combo
- [ ] Knative + Kourier on Talos+Cilium smoke test
- [ ] Assemble the full stack once; measure real idle RAM; fix the published spec if needed
- [ ] WSL2 end-to-end run (least-verified platform)
- [ ] Gitea seed + force-push catch-up mechanism prototype

### Phase 2 — Platform tree + prereqs final (early August)
- [ ] `gitops/` app-of-apps with sync waves, Application health check in argocd-cm,
      ServerSideApply/SkipDryRun where needed
- [ ] `cloudbox-init.sh` final image list (GHCR-hosted, pinned tags, nothing from Docker Hub)
- [ ] CI: shellcheck + weekly full-bootstrap run (verify runner fits; else self-hosted/nightly local)
- [ ] Announce updated prereqs to JavaZone (their page must match reality)

### Phase 3 — Labs (August)
- [ ] Modules 1–5 to the outcome/verify/hints/solve pattern; refactor existing Lab 01/02
      content into it (Lab 01 must actually install Cilium; Lab 02's storageClass must exist)
- [ ] Fault library for module 5 (incl. one "AI's obvious answer is wrong" fault)
- [ ] Stretch modules S1–S3 (depth per decision 2)
- [ ] Catch-up scripts per module; git tags per module

### Phase 4 — Slides + helpers (mid-August)
- [ ] Slidev rewrite: sovereignty narrative, architecture diagram, one framing section per
      module, accurate MinIO/RustFS story, "keep tinkering" wrap-up
- [ ] Recruit 4–8 helpers (CNCF/GDG networks); helper cheat-sheet of known failure modes

### Phase 5 — Rehearse + harden (last 2 weeks of August)
- [ ] Two timed full dry-runs (one on a clean machine, one driven by a guinea pig,
      one leg over phone hotspot); cut scope by timing data
- [ ] Offline test: airplane-mode laptop, everything from pre-pulled images
- [ ] Pre-record demo videos as last-resort fallback; final version pins; tag `javazone-2026`

## 5. Risks (updated)

| Risk | Mitigation |
|---|---|
| Attendees hit broken prereqs **today** | Phase 0 this week; support channel in README |
| Half the room can't run locally (2022 precedent) | Pre-flight gate + decision-1 fallback path + helpers |
| Docker Hub NAT rate-limit | Everything on GHCR, pinned; optional room registry mirror (registry-pi pattern) |
| RustFS immature | Explicit switch triggers mid-Aug → SeaweedFS; one-values-file change |
| BuildKit/Knative on Talos unrehearsed | Phase 1 spikes before any lab depends on them |
| 16 GB laptops OOM | Backstage last + demo fallback; Hubble presenter-only; honest published spec |
| Overrun | 4-core design with slack; stretch absorbs speed; cut by dry-run data |
| Speaker illness | Both speakers rehearse *all* modules; slides + labs self-contained |
| Version drift July→Sept | Pin everything now; weekly CI bootstrap; re-verify pins late Aug |
| Unknown headcount (30 vs 80) | Ask organizers now; helper count scales with cap |

## 6. Decisions (made 2026-07-13, Hans)

1. **Environment strategy: local-first + devcontainer lifeboat.** Talos-in-Docker on the
   attendee's laptop is the primary path, gated by `install.sh --check`; the repo ships a
   devcontainer so pre-flight failures open the same content in GitHub Codespaces.
2. **Argo Workflows: presenter demo + self-paced stretch lab.** The build→Zot→deploy
   pipeline is demoed live; the lab stays in the repo for fast attendees and home use.
3. **AI segment: yes, as designed.** Module 5 ships with a seeded-fault library, agent-
   assisted diagnosis, and one fault where the obvious AI answer is wrong.
4. **Repo name: rename to `jz-2026-platform-engineering` now.** GitHub redirects the old
   URL printed on the conference page.
5. **Object storage: RustFS stays the default**, SeaweedFS is the rehearsed Plan B with the
   mid-August switch triggers in docs/RESEARCH.md.
