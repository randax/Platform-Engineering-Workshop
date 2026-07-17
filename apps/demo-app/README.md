# demo-app — the app-team golden path's sample

A tiny Go web service that **uses** the dependencies the platform composes for
it, so "deploy from source" shows a real wired app, not a static page:

- **Postgres** (`DATABASE_URL`) — a live visit counter in a real table.
- **S3 bucket** (`S3_*`) — writes a marker object and lists the bucket.

It's resilient: if a dependency is still composing, the page shows an inline
"not ready" note instead of crashing.

## Deploy it (from the Cloudbox Console)
Applications → **New application** → **Source: Build from a repo** →
`cloudbox/demo-app`, branch `main`, path `.` → tick a database + bucket → Deploy.
The platform builds it in-cluster (Argo + BuildKit → Zot) and composes the
workload + Postgres + bucket. Then change the code, push, and hit **Redeploy**.

Or start fresh: **Source: Start from a template** → the console forks this repo
into a new `cloudbox/<name>` of your own (Gitea's generate API), then builds and
deploys it — clone your new repo and iterate from there. This repo is marked a
Gitea *template* so it can be the source of that fork.

## Build
Multi-stage: a golang builder compiles a static binary; the runtime is
`scratch` + a CA bundle. Go deps are **vendored**, so the build needs no module
proxy. An in-cluster build pod can't reach the internet (offline cluster), so
the builder base is pulled **from your own Zot registry** — seed it once, the
same way module 07 seeds busybox:

```sh
crane copy --insecure public.ecr.aws/docker/library/golang:1.25-alpine \
  localhost:30500/library/golang:1.25-alpine
```

This repo is seeded into the in-cluster Gitea by `scripts/seed-gitea.sh` and
lives in the platform repo under `apps/demo-app`.
