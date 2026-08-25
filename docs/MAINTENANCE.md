# Maintenance — keeping the pins honest

Everything in this repo is pinned (principle 14). Pins rot. This is the runbook
for the rot, written so the recurring work is *reading a report*, not
re-researching the stack.

Read this before doing a "re-verify the versions" pass — it exists precisely so
that pass costs an hour, not an afternoon.

## The five mechanized checks

| Question | Answered by | When |
|---|---|---|
| Do our files agree with **each other**? | `scripts/check-consistency.sh` | every push/PR (`ci.yaml`) |
| Are the **VENDOR.md files still true**? | `scripts/check-vendor-drift.sh` | guard 2 every push/PR (`ci.yaml`); guard 1 weekly + on `gitops/components/**` PRs (`vendor-drift.yaml`) |
| Does every pinned image still **exist** upstream? | `.github/workflows/images-gate.yaml` | weekly + on `images.txt` PRs |
| Has any pin fallen **behind** upstream? | `scripts/check-upstream.sh` | weekly (`upstream-check.yaml`) |
| Does the whole attendee flow still **work**? | `.github/workflows/bootstrap-test.yaml` | weekly |

A green `bootstrap-test.yaml` means *the workshop works on Linux, on one cluster,
with no timing races*. Three rehearsals each found blockers it cannot see by
construction — see [`REHEARSALS.md`](REHEARSALS.md).

Dependencies inside our own code (Go modules, the Slidev deck, GitHub Actions)
are Dependabot's job — see `.github/dependabot.yml`.

Nothing in this list is part of the attendee flow. `check-upstream.sh` and
`check-vendor-drift.sh`'s guard 1 need internet by design; everything attendees
run must work offline.

## The weekly signal

`upstream-check.yaml` runs `check-upstream.sh` and rewrites **one** long-lived
issue labelled `upstream-drift` with the current table. There is no PR spam and
no per-component issue: one report, rewritten, always current.

Run it yourself any time:

```sh
mise run upstream                    # or: ./scripts/check-upstream.sh
./scripts/check-upstream.sh --only cilium-chart,argocd
./scripts/check-upstream.sh --json   # for scripting
```

Status column: `ok` · `pre` (only the prerelease moved) · `patch` · `minor` ·
`major` · `error` · `SKIP`.

## What the report is *not*

It is not a to-do list. Being behind upstream is a fact, not a defect — a
workshop that runs offline on 80 laptops values *proven* over *latest*. The
default answer to a `patch` row three weeks before the event is "no".

Bump when there is a reason: a fix we need, a CVE that matters, a feature the
lab depends on, or the pre-event re-verify pass where we deliberately land on
current versions with a full rehearsal behind them.

## Adding something to the report

Add a row to `scripts/upstream.list`. It holds **no version numbers** — each row
says where the pin *lives* (`env:` / `mise:` / `image:` / `chart:` / `file:`)
and where upstream *is* (`github-release` / `github-tag` / `helm-index` /
`registry-tag`). The file's header documents every field.

Two things to get right:

- **Deliberate holds** go in the `track` column as a regex (CNPG is held at
  `^1\.28\.` on purpose), with a comment saying why. Fix the row, not the pin,
  when a report nags about a version we do not want.
- **Derived versions** do not get a row. Cilium's images come out of the Cilium
  chart; dex and redis out of the ArgoCD manifest; the Talos system images out
  of the Talos release. Tracking them separately invites a bump that no
  re-vendor can produce. The bottom of `upstream.list` lists all of them.

`check-consistency.sh` fails if a row stops resolving to a real pin, so a moved
file cannot silently retire a check.

## Keeping the VENDOR.md files honest

`gitops/components/*/VENDOR.md` is what step 2 above tells you to trust. It was
not trustworthy: **11 of 19 were found wrong**, every one by accident while
doing something else — a missing PSA `privileged` label that hangs every PVC, a
missing `config-domain` entry that 404s every Knative URL, config keys that a
literal re-vendor silently drops. They all rotted the same way: accurate when
written, stale at the next bump, because nothing ever compared them to
anything. `scripts/check-vendor-drift.sh` is that comparison. Two guards:

**Guard 1 — the re-render gate** (strong; network + helm; `vendor-drift.yaml`).
For every file whose VENDOR.md carries a ```` ```curation ```` block with a
`render` recipe, it reproduces the pristine upstream artifact and diffs it. Every
hunk must have an `allow  <file>  <id>  <why>` line, where `<id>` is a digest of
the hunk's *changed lines only* — so a curation keeps its id when upstream moves
it around, and identical curations (the halved requests, repeated per Deployment)
share one line. Two ways to fail:

- an **unlisted hunk** — undocumented curation, or upstream moved under us;
- an **`allow` line whose hunk has vanished** — the curation it documents was
  lost in a re-vendor. That is the failure mode that produced most of the 11.

Components with no reproducible upstream artifact (the hand-written ones) have
no `render` recipe and are covered by guard 2 instead.

**Guard 2 — the token-coverage lint** (weak but broad; offline; `ci.yaml`).
Every file *not* covered by guard 1 has its load-bearing knobs extracted —
nodePorts, container/service ports, env var names, image refs, resource
requests/limits, `pod-security.kubernetes.io/*` and other slash-keys, probe
paths and hostPaths, RBAC resources, volume shapes, readiness checks — and each
token must appear *somewhere* in that component's VENDOR.md. Incidental tokens
get an `ignore <token>  <why>` line in the same block; use it sparingly, with a
reason, rather than loosening the extraction.

**Read the honest limits before trusting a green run.** The guard-1 allowlists
were bootstrapped from the tree as it stood — that day's diff *was* the accepted
curation — so green means "nothing changed since", not "someone audited it". And
guard 2 proves a knob is *mentioned*, not that the sentence next to it is
correct or current. The script prints both caveats on every run.

## Doing a bump

1. **Change the pin where it actually lives** — `scripts/versions.env`,
   `mise.toml`, `scripts/images.txt`, or the component's rendered manifest.
   Never in two places: if `check-consistency.sh` compares them, it will tell
   you which pair drifted.
2. **Re-vendor if the component ships a chart or a release YAML.** Every
   `gitops/components/*/VENDOR.md` carries its own re-vendor recipe *and* the
   workshop curation to re-apply afterwards (halved resource requests, NodePort
   services, repointed images). Re-applying that curation is the part that
   actually takes judgment — the VENDOR.md exists so it is not re-derived from
   scratch each time.

   **Trust the re-render for *what* changed and the VENDOR.md for *why*.**
   `./scripts/check-vendor-drift.sh --only <component>` re-runs the recipe and
   diffs it against the vendored file: that diff, not the prose, is the
   authority on what actually differs from upstream. The prose is the authority
   on why each difference is there — and it is only as good as the person who
   last wrote it. If the two disagree, the diff is right and the prose needs
   fixing. Workflow after a bump:

   ```sh
   ./scripts/check-vendor-drift.sh --only <component>            # what broke
   # …re-apply the curation the failures name…
   ./scripts/check-vendor-drift.sh --update --only <component>   # re-id the hunks
   git diff gitops/components/<component>/VENDOR.md              # READ THIS
   ```

   `--update` only does the bookkeeping (hunk ids); every new hunk arrives
   labelled `TODO describe:` and you write the label. A `TODO` left in the tree
   is a curation nobody has explained yet.
3. **Re-pin the images the new version ships.** For a chart:
   `helm template … | grep image:`. For a release YAML: read the digests out of
   it. Everything deployed must appear in `scripts/images.txt` or
   `check-consistency.sh` fails — that is the offline guarantee. A **tag** pin
   must publish both linux/amd64 and linux/arm64 (cloudbox-init.sh mirrors tag
   pins per-arch and errors on an index missing the host's platform), unless
   the repo is listed in `MIRROR_ARCH_EXEMPT` in `versions.env` — deliberately
   single-arch, runs emulated (Backstage);
   `images-gate.yaml` enforces this, so an upstream that drops an arch shows up
   in the weekly report, not on an attendee's laptop.
4. **`./scripts/check-consistency.sh`** must be green before the PR.
5. **Let `bootstrap-test.yaml` prove it.** A pin that passes static checks and
   breaks the cluster is the failure mode this whole file exists to prevent.

Bumps that touch the cluster shape (Talos, Kubernetes, Cilium) deserve their own
PR and their own rehearsal run. Batch the boring ones.

### The Cilium bump has two operator surfaces to re-read

Re-vendoring the chart `.tgz` is not the whole job. `create-cluster.sh` passes
`--set "operator.extraArgs[0]=--ingress-default-request-timeout=24h"` and four
of our ingresses carry `ingress.cilium.io/request-timeout: "0s"`. Both are
**operator** surfaces, and both are load-bearing: without them Envoy's 15 s
default route timeout applies to every hostname in the workshop (`git push`,
the Console's SSE stream, ArgoCD's watches). On a bump, confirm

* the flag still exists and still means what it means —
  `operator/pkg/ingress/cell.go`, and note that
  `operator/pkg/model/ingestion/ingress.go` SKIPS the flag when it is zero, so
  "0" is not "no timeout" there;
* the annotation is still parsed — `operator/pkg/ingress/annotations/annotations.go`;
* the flag still renders:
  `helm template cilium scripts/manifests/cilium-<v>.tgz --set ingressController.enabled=true --set "operator.extraArgs[0]=--ingress-default-request-timeout=24h" | grep ingress-default-request-timeout`.

`docs/HAZARDS.md` carries the full reasoning.

### The `tbx` pin is a special case

`TBX_VERSION` in `scripts/versions.env` pins the talos-box binary — the primary
substrate's *entire* implementation. It is not installed by mise (no backend publishes
it yet: upstream #95/#96/#101), so nothing enforces at runtime what an attendee actually
has on PATH. Bumping it means all three of:

1. **Bump the `mise.toml` comment in the same commit.** The pin lives as the commented
   `# tbx = "…"` line next to the install note; `check-consistency.sh` check 10 compares
   it to `TBX_VERSION` and fails if they drift. That comment is the only other copy —
   do not add a third.
2. **Re-read upstream before trusting the flags.** `scripts/substrate/tbx.sh` drives
   `tbx up -f`, `tbx status -o json`, `tbx version` and
   `tbx cluster destroy <cluster> --force`, and `cloudbox-init.sh` drives
   `tbx cache pull --talos-version`. Read upstream `internal/config/config.go` for
   cluster-yaml schema changes (our `scripts/substrate/cloudbox.tbx.yaml.tmpl` is a
   projection of it). We deliberately consume **no** `tbx manifests` section any more —
   `balloon` was deprecated into an error, and the `mirrors` catch-all turned out to be
   actively harmful (see `docs/HAZARDS.md`) — so a section rename upstream is no longer
   something that can break us silently. Two things upstream *can* still move under us:
   the `tbx status -o json` shape, and `checkOvercommit`'s reserve in
   `internal/balloon/manager.go` (mirrored as `TBX_HOST_RESERVE_GIB` in `versions.env`;
   if the upstream default moves, move ours in the same commit or every 16 GB laptop
   fails to start a cluster).
   Also re-check the version STRING: `tbx_version_check()` in `scripts/lib.sh` parses
   field 2 of `tbx version` and both `install.sh --check` and the tbx preflight compare it
   to `TBX_VERSION`.
3. **Re-pin as soon as a release contains `053aecb`.** At v0.1.1 the Linux
   `bridge-netfilter` doctor check turns an unprivileged `iptables -S FORWARD`
   (exit 4) into a FAIL, so detection silently falls back to docker on hosts
   where iptables cannot be inspected without privileges; `053aecb` makes it a
   WARN with a sudo remediation. When the pin moves past it, drop the
   "best-effort at v0.1.1" wording from the README's platform matrix and retire
   the matching `docs/HAZARDS.md` entry.
4. **Re-run a full tbx rehearsal.** There is **no CI for this substrate** —
   `bootstrap-test.yaml` runs Docker on a GitHub runner and always will. A tbx pin that
   passes `check-consistency.sh` has been proven to agree with itself and nothing more.

Nothing vendored depends on the tbx version: talos-box supplies no manifests we keep
(its curated `cni:` is deliberately *not* used — we install Cilium ourselves on both
substrates, which check 10 also asserts). So there is nothing to re-vendor, and
`check-upstream.sh` tracks the release via the `tbx` row in `scripts/upstream.list`.

## The first-party images

`ghcr.io/randax/cloudbox-{portal,uploader,resizer,grafana}` are ours, so they do
not appear in the upstream report. Their release path is in
[`scripts/README.md`](../scripts/README.md) — conventional commit →
release-please PR → merge → tag → GHCR publish, with the pinned refs updated by
release-please itself.

## Before the event

The pre-event re-verify pass is the one time the answer to the report is
"bump most of it":

- [ ] Read the `upstream-drift` issue; decide per row, not in bulk
- [ ] Bump + re-vendor, one component per commit
- [ ] `./scripts/check-consistency.sh` green
- [ ] `./scripts/check-vendor-drift.sh` green, and every VENDOR.md diff it
      produced actually read (that diff is the re-vendor's real changelog)
- [ ] `bootstrap-test.yaml` green on the full module range
- [ ] One real prework run on a clean machine: `dev-setup.sh` →
      `cloudbox-init.sh` → `install.sh --check`
- [ ] Refresh the "verified <date>" headers in `scripts/versions.env`,
      `scripts/images.txt`, `docs/RESEARCH.md`, `docs/STACK.md`
- [ ] Tag `javazone-2026`
