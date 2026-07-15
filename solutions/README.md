# solutions/ — canonical end-state per module

`solutions/module-0N/` describes the exact platform-repo state at the **end** of module N.
Each module directory is **cumulative** (it contains everything from earlier modules too),
so catching up to module N never requires replaying modules 2..N-1.

Consumed by `./scripts/catch-up.sh <module>`; also readable by humans who want to diff
their state against the canonical one. Each module's `solve.sh` is designed to be run
against its `verify.sh` for CI regression (job tracked in issue #10).

## Layout of a module directory

| Entry | Meaning |
|---|---|
| `apps/` | The exact contents of `gitops/apps/` at the end of the module: copies of the enabled catalog Applications **plus** the lab-authored Applications (`demo.yaml`, `platform-api.yaml`). `catch-up.sh` copies these into the attendee's repo and force-pushes. |
| `enabled.txt` | Provenance: which of the `apps/` files are verbatim copies from `gitops/catalog/` (or wave-0 `gitops/apps/`). CI should diff each listed file against its source so the copies can't drift when the catalog changes. |
| `components/` | Solution-owned component subtrees. Each child dir (e.g. `components/demo/`) is the canonical content of `gitops/components/<dir>/` — manifests attendees normally push themselves during the labs (welcome ConfigMap, `app-db` cluster, XRD/Composition, ksvc, hello-site). |
| `post.sh` | Imperative steps GitOps can't carry (S3 bucket creation, the module-07 in-cluster image build). Idempotent; run after ArgoCD converges. |
| `README.md` | Module-specific notes (only where needed). |

Module 01 has no GitOps state (see `module-01/README.md`). `module-05` is identical to
`module-04` by design — module 05's faults live in `faultlab-*` namespaces outside GitOps
(`lab/05-debug-with-ai/restore.sh clean` removes them). Module 08's star-task database
(`console-db`) is deliberately *not* here: the portal creates it straight against the
Kubernetes API, outside git — that gap is the module's explain-back. Module 09's `images`
bucket needs no post.sh: a Job inside the picture-pipeline component creates it.

> `catch-up.sh` performs a full catch-up: it *replaces* the clone's `gitops/apps` and
> `gitops/components` with the canonical state (module `apps/`, the repo's platform
> components, and the module's solution `components/`), force-pushes, waits for every
> enabled Application to reach Synced/Healthy, and then runs the module's `post.sh`.

## What catch-up looks like for an attendee

```bash
./scripts/catch-up.sh 3               # jump to the end of module 03
./scripts/catch-up.sh 3 --rebuild     # cluster is truly broken: destroy, recreate,
                                      # bootstrap, seed, then catch up (~10 min)
lab/03-data/verify.sh                 # confirm
```

## Enabled catalog apps per module (cumulative)

| Module | apps enabled |
|---|---|
| 02 | local-path-provisioner (wave 0) + demo |
| 03 | + cnpg-operator, rustfs |
| 04 / 05 | + crossplane, platform-api |
| 06 | + knative-serving |
| 07 | + zot, argo-workflows |
| 08 | + portal |
| 09 | + knative-eventing, picture-pipeline |

Backstage is deliberately absent: it's the module-08 *presenter demo* (a ~2 GB
amd64-only image), so catch-up never forces it onto attendee laptops. Enable it
yourself from `gitops/catalog/backstage.yaml` if you want to run the demo at home.
