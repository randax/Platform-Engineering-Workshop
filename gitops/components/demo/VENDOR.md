# Vendored: demo (nothing — this directory is the attendee's)

| | |
|---|---|
| Source | **The attendee.** Nothing ships here, from upstream or from us. |
| Files | None. This file exists so the directory does, and so the next person reads why. |

## Why it is empty

`demo` is the namespace a workshop participant fills, and filling it *is* the
lab. Every module hands them a manifest and asks them to copy it into their own
platform repo:

| Module | copies | into |
|---|---|---|
| 02 | `lab/02-gitops/welcome.yaml` | `gitops/components/demo/welcome.yaml` |
| 03 | `lab/03-data/postgres-cluster.yaml` | `gitops/components/demo/` |
| 04 | `lab/04-self-service/examples/my-database.yaml` | `gitops/components/demo/` |
| 06 | `lab/06-serverless/hello-ksvc.yaml` | `gitops/components/demo/` |
| 07 | `lab/07-ci/hello-site.yaml` | `gitops/components/demo/` |
| 08 | `lab/08-portal/portal-access.yaml` (+ `portal-projects-access.yaml`) | `gitops/components/demo/` |

The `demo` Application that syncs this path is itself something the attendee
creates in module 02 (`lab/02-gitops/demo-app.yaml` → `gitops/apps/demo.yaml`).

**So a manifest checked in here is a bug**, and one this repo has already had: a
`catch-up.sh 9` run and a "enable stretch goals for review" commit were pushed
to `main`, which left seven of these files and eighteen extra Applications in
`gitops/apps/` on every fresh clone. The result was that modules 02–09 had
nothing left to enable and lab 02's own question — *"what single Application did
it already create, and why is that dir called wave 0?"* — had no true answer.

If you need a cluster at some module's end state, that is what
`./scripts/catch-up.sh <n>` and `solutions/module-<n>/` are for. Do not commit
the result.
