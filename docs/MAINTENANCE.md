# Maintenance — keeping the pins honest

Everything in this repo is pinned (principle 14). Pins rot. This is the runbook
for the rot, written so the recurring work is *reading a report*, not
re-researching the stack.

Read this before doing a "re-verify the versions" pass — it exists precisely so
that pass costs an hour, not an afternoon.

## The four mechanized checks

| Question | Answered by | When |
|---|---|---|
| Do our files agree with **each other**? | `scripts/check-consistency.sh` | every push/PR (`ci.yaml`) |
| Does every pinned image still **exist** upstream? | `.github/workflows/images-gate.yaml` | weekly + on `images.txt` PRs |
| Has any pin fallen **behind** upstream? | `scripts/check-upstream.sh` | weekly (`upstream-check.yaml`) |
| Does the whole attendee flow still **work**? | `.github/workflows/bootstrap-test.yaml` | weekly |

Dependencies inside our own code (Go modules, the Slidev deck, GitHub Actions)
are Dependabot's job — see `.github/dependabot.yml`.

Nothing in this list is part of the attendee flow. `check-upstream.sh` needs
internet by design; everything attendees run must work offline.

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

## Doing a bump

1. **Change the pin where it actually lives** — `scripts/versions.env`,
   `mise.toml`, `scripts/images.txt`, or the component's rendered manifest.
   Never in two places: if `check-consistency.sh` compares them, it will tell
   you which pair drifted.
2. **Re-vendor if the component ships a chart or a release YAML.** Every
   `gitops/components/*/VENDOR.md` carries its own re-vendor command *and* the
   workshop curation to re-apply afterwards (halved resource requests, NodePort
   services, repointed images). Re-applying that curation is the part that
   actually takes judgment — the VENDOR.md exists so it is not re-derived from
   scratch each time.
3. **Re-pin the images the new version ships.** For a chart:
   `helm template … | grep image:`. For a release YAML: read the digests out of
   it. Everything deployed must appear in `scripts/images.txt` or
   `check-consistency.sh` fails — that is the offline guarantee. A **tag** pin
   must publish both linux/amd64 and linux/arm64 (cloudbox-init.sh mirrors tag
   pins per-arch and errors on an index missing the host's platform);
   `images-gate.yaml` enforces this, so an upstream that drops an arch shows up
   in the weekly report, not on an attendee's laptop.
4. **`./scripts/check-consistency.sh`** must be green before the PR.
5. **Let `bootstrap-test.yaml` prove it.** A pin that passes static checks and
   breaks the cluster is the failure mode this whole file exists to prevent.

Bumps that touch the cluster shape (Talos, Kubernetes, Cilium) deserve their own
PR and their own rehearsal run. Batch the boring ones.

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
- [ ] `bootstrap-test.yaml` green on the full module range
- [ ] One real prework run on a clean machine: `dev-setup.sh` →
      `cloudbox-init.sh` → `install.sh --check`
- [ ] Refresh the "verified <date>" headers in `scripts/versions.env`,
      `scripts/images.txt`, `docs/RESEARCH.md`, `docs/STACK.md`
- [ ] Tag `javazone-2026`
