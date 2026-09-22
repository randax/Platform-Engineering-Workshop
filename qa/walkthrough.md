# QA Runbook: full attendee walkthrough (venue mode)

| | |
|---|---|
| **Tier** | Pre-delivery gate — the agent plays a diligent attendee |
| **Target** | Platform-Engineering-Workshop, this checkout, modules 00–10 in order |
| **Estimated duration** | 4–6 h |
| **Destructive** | Creates/destroys the cloudbox cluster; pushes to the in-cluster Gitea only; never touches the mirror volume or this Git checkout's history |
| **Network** | **Venue mode: upstream cut for the whole run.** Any step that needs upstream network is a FAIL by definition, except the badged online-only steps |
| **Runbook version** | record `git rev-parse HEAD` in your report |

## How to execute this runbook (agent instructions)

You are a diligent attendee with a QA reporter's eyes. Per module: **work the exercise from the module's README alone** (`lab/NN-*/README.md`), then run `verify.sh` as the pass check. If your own attempt fails verify, run `solve.sh`, re-run `verify.sh`, and report the divergence: *instructions misled me* (friction — quote the misleading passage) is a different finding from *rails broken* (`solve.sh` also fails verify — a bug).

Verdicts: **PASS**, **PASS-with-friction**, **FAIL**, plus two badges counted outside pass/fail: **SKIPPED-human-only** (explain-backs, live demos) and **SKIPPED-online-only** (the one documented exception). Friction — confusing instructions, doc drift, misleading output — is a first-class result even on passing modules. Do not improvise recovery beyond the solve.sh fallback protocol; capture evidence, record, move on (module dependencies are stated per charter; `./scripts/catch-up.sh <module>` is the sanctioned skip-ahead if a hard-failed module blocks later ones — record its use).

**Observe-and-attest**: some steps have no `verify.sh` coverage but *are* observable. Those carry their own expected observations here; you attest to them in the report.

**Report destination**: one GitHub issue per run on `randax/Platform-Engineering-Workshop`, label `qa-run`, title `QA walkthrough <date>`, template at the bottom.

## Preflight

Report BLOCKED if these don't hold:

1. Home prep done: `./scripts/install.sh --check` exits 0 (mirror populated, CLIs pinned). If module 10 beat 1 is in scope: `ollama list` shows `qwen3:4b`.
2. **Venue mode established and proven.** Cut upstream at the OS level — macOS: `networksetup -setairportpower <wifi-device> off` (find the device with `networksetup -listallhardwareports`); Linux: `nmcli networking off`. Then prove the cut:
   - `curl -m 5 -s https://registry-1.docker.io/v2/` **fails** (timeout/unreachable), and
   - `curl -s localhost:5001/v2/_catalog` still answers (the mirror is local).
   Both together are the venue-mode invariant; re-check them whenever a module behaves oddly. Note: `create-cluster.sh` configures the cluster's registry mirrors with `skipFallback: false`, so a missing mirror image *silently* reaches for upstream — under venue mode that surfaces as a hang/timeout; treat any such hang as a FAIL with the image ref as evidence.
3. No cloudbox cluster running (else `./scripts/destroy-cluster.sh`).

## Charters (one per module)

For every charter, unless stated otherwise: **Steps** = work `lab/NN-*/README.md` as written; **Pass criteria** = that module's `verify.sh` exits 0 after *your* attempt (fallback protocol otherwise); **On failure** = capture your commands, verify.sh output, `kubectl get pods -A | grep -v Running`, and — for GitOps modules — the ArgoCD app list (`kubectl -n argocd get applications`).

### M00 — Setup gate

`./scripts/install.sh --check` and `./lab/00-setup/verify.sh` both exit 0. This duplicates the smoke's C1 deliberately — it anchors the run.

### M01 — Talos + Cilium cluster

Work the README: `./scripts/create-cluster.sh`, then the talosctl exploration.
Observe-and-attest (verify does not cover the exploration): `talosctl -n 10.5.0.2 get members` lists both nodes; the machineconfig shows `cni: none` and kube-proxy disabled. Timing: record cluster-up duration.

### M02 — GitOps: Gitea + ArgoCD (depends on M01)

Work the README: `bootstrap-gitops.sh`, `seed-gitea.sh`, deliver the demo app + welcome ConfigMap via git push with a real owner name.
Observe-and-attest: the self-heal experiment — `kubectl edit` the ConfigMap, then watch ArgoCD snap it back (allow for the ~3 min poll; UI Refresh is fair). Attest the poisoned value did not survive.

### M03 — Data services: CNPG + RustFS (depends on M02)

Work the README: enable operators via git, deliver `app-db`, create bucket `app-assets`, upload, presign.
Observe-and-attest: fetch the **presigned URL** with `curl` and attest HTTP 200 with the object's bytes (the module's stated trophy; verify only checks bucket+object). Venue note: use the in-cluster aws-cli image fallback if no host S3 CLI — it's pre-mirrored.

### M04 — Self-service: Crossplane (depends on M02, M03)

Work the README: enable crossplane, ship XRD + Composition, push the 10-line `WorkshopDatabase` example.
Expected extras: `my-db` reaches Synced **and** Ready; composed `my-db-pg` healthy; `my-db-assets` bucket exists. Allow 2–3 min readiness bubbling.

### M05 — Debug it (depends on M02)

**Vacuous-pass hazard**: verify passes with zero injected faults — you must inject. Run `./lab/05-debug-with-ai/inject.sh` for at least faults 1 and 4, diagnose each from live state (write the one-sentence diagnosis in your report — that's the attest), fix or `restore.sh`, then verify.
SKIPPED-human-only: the AI-loop beat and the "agent claimed X, I checked Y" deliverable.

### M06 — Serverless: Knative (depends on M02)

Work the README: enable knative-serving, deliver the ksvc, curl through Kourier :31080 with the Host header.
Observe-and-attest: **cold start** — from scale-zero, first curl returns 200 and you record the latency; expect ≤ ~2 min for the subsequent scale-back-to-zero (verify covers the 200 and scale-to-zero, not the timing; attest both timings).

### M07 — In-cluster CI: Argo Workflows + BuildKit + Zot (depends on M02; repo self-flags "least-rehearsed")

Work the README **with one venue-mode substitution**: the documented base-image seed is `crane copy docker.io/library/busybox:1.37.0 localhost:30500/...` — under venue mode that reaches Docker Hub and must fail. Source it from the local mirror instead (`crane copy localhost:5001/library/busybox:1.37.0 localhost:30500/library/busybox:1.37.0`). **Report the documented command as a standing friction finding** (docs point at Docker Hub at a venue): this is known; quote whether the README still does it.
Pass extras: a `build-hello-site-*` Workflow Succeeded; the image appears in Zot's catalog; the Deployment serves.

### M08 — Portal: Cloudbox Console (depends on M02, M04)

Work the README: enable the portal, grant access, then create `console-db` **through the New-database form** (kubectl bypass is exactly what QA must not do here — verify can't tell the difference, so your attest is the only witness to the form path).
Observe-and-attest: `/healthz` returns `ok` on :30600; the form flow completed without console errors.
SKIPPED-human-only: the Backstage presenter demo and the four going-deeper console flows (the build-from-repo flow is additionally blocked offline by the missing golang base — note it).

### M09 — Capstone: picture pipeline (depends on M03, M06, M08 — or `catch-up.sh 8`)

Work the README: enable eventing + pipeline, upload a photo at :30600/gallery (a multipart `curl` POST is a fair attendee-equivalent if the browser is unavailable), check `originals/` → `thumbs/` matching in bucket `images`. Known flake: a Trigger latching `BrokerNotConfigured` — the documented annotate-to-reconcile workaround applies; record if you needed it.
Observe-and-attest (zero verify coverage — the audit's biggest gap): enable the 5-app observability set and **query Grafana on :30030 via its HTTP API** for the upload trace; attest the trace exists. This gap is filed as a workshop issue — link your findings to it.

### M10 — Day-2 ops: rollback (depends on M02)

Work the README: two-phase `inject.sh` (seed, then fault), diagnose, `git revert` + push (live edits don't count — verify is two-sided: Git clean AND rollout healthy).
SKIPPED-human-only: both kagent beats. SKIPPED-online-only: the OpenCode Zen beat (the sole documented at-venue network exception). If on Linux, note whether the documented `host.docker.internal → 10.5.0.1` ModelConfig fix is still accurate in the docs (attest text only; don't execute the beat).

### M-cleanup — always run

`./scripts/destroy-cluster.sh`; mirror catalog still non-empty; **restore network** (`networksetup -setairportpower <dev> on` / `nmcli networking on`) and prove it (`curl -m 10 -s https://registry-1.docker.io/v2/` answers).

## Standing rot watchlist (check during the run, report regardless of verdicts)

- README architecture diagram vs `versions.env` Cilium pin (drift already known: "1.19" vs 1.20.0 — still there?).
- The "verified 2026-07-13, re-verify late August" comments in `mise.toml`/`versions.env`/`images.txt` vs the Sept 2–3 delivery — has the re-verify happened?
- `./scripts/check-consistency.sh` exits 0.
- Module 10's hosted-model names and the aws-cli image tag baked into module 03's hint — still current?

## Report template

```markdown
## QA walkthrough — <date>

- workshop commit: / host: / venue mode proven: yes|no
- catch-up.sh used at: <modules or none>

| Module | Verdict | Own attempt passed verify? | solve.sh needed? | Duration | Notes |
|---|---|---|---|---|---|
| 00 | | | | | |
| 01 | | | | | |
| 02 | | | | | |
| 03 | | | | | |
| 04 | | | | | |
| 05 | | | | | |
| 06 | | | | | |
| 07 | | | | | |
| 08 | | | | | |
| 09 | | | | | |
| 10 | | | | | |

### Attestations (observe-and-attest results)
<M01 exploration, M02 self-heal, M03 presigned URL, M05 diagnoses, M06 cold start, M08 form path, M09 Grafana trace — one line each>

### SKIPPED-human-only list (for the rehearsing instructor)
<every badged step encountered>

### Friction log
<numbered; instructions-misled-me findings quote the misleading passage>

### Failures
<per failure: module, expected vs observed, evidence; venue-mode leaks name the exact image/URL reached for>

### Rot watchlist results
<the four standing checks>
```
